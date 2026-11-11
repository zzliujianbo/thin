test "live ring retains bounded events until explicitly reclaimed" {
    const a = std.testing.allocator;
    var ring = LiveRing{ .allocator = a, .max_count = 2, .budget = 4 };
    defer ring.deinit();
    try ring.push(1, try a.dupe(u8, "ab"));
    try ring.push(3, try a.dupe(u8, "cd"));
    const pending = try a.dupe(u8, "e");
    try std.testing.expectError(error.RingFull, ring.push(4, pending));
    try std.testing.expectEqual(@as(usize, 2), ring.items.items.len);
    try std.testing.expectEqualStrings("ab", ring.items.items[0].json);
    try ring.acknowledgeRange(2, 2, 0, 2, 4);
    try std.testing.expectEqual(@as(u64, 2), ring.reclaimed_through);
    try ring.push(4, pending);
    try ring.acknowledgeRange(2, 2, 0, 4, 4);
    try std.testing.expectEqual(@as(usize, 0), ring.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), ring.bytes);
}
test "live ring acknowledgement validates authority and future watermark" {
    const a = std.testing.allocator;
    var ring = LiveRing{ .allocator = a };
    defer ring.deinit();
    try ring.push(3, try a.dupe(u8, "a"));
    try ring.push(5, try a.dupe(u8, "b"));
    try std.testing.expectError(error.StaleControl, ring.acknowledge(2, 1, 3, 5));
    try std.testing.expectError(error.InvalidSequence, ring.acknowledge(2, 2, 6, 5));
    try std.testing.expectEqual(@as(usize, 2), ring.items.items.len);
    try ring.acknowledge(2, 2, 3, 5);
    try ring.acknowledge(2, 2, 2, 5);
    try std.testing.expectEqual(@as(u64, 3), ring.reclaimed_through);
    try std.testing.expectEqual(@as(u64, 5), ring.items.items[0].seq);
}
test "live ring retires only proven ranges and keeps an earlier hole" {
    const a = std.testing.allocator;
    var ring = LiveRing{ .allocator = a, .max_count = 5 };
    defer ring.deinit();
    for (1..6) |seq| try ring.push(seq, try a.dupe(u8, "e"));
    try std.testing.expectError(error.StaleControl, ring.acknowledgeRange(2, 1, 2, 3, 5));
    try std.testing.expectError(error.InvalidInput, ring.acknowledgeRange(2, 2, 4, 3, 5));
    try std.testing.expectError(error.InvalidSequence, ring.acknowledgeRange(2, 2, 2, 6, 5));
    try ring.acknowledgeRange(2, 2, 2, 3, 5);
    try std.testing.expectEqual(@as(u64, 3), ring.highest_acknowledged);
    // Position 1 is still unproven, so the exact-recovery cursor may not move.
    try std.testing.expectEqual(@as(u64, 0), ring.reclaimed_through);
    try std.testing.expectEqual(@as(usize, 3), ring.items.items.len);
    try std.testing.expectEqual(@as(u64, 1), ring.items.items[0].seq);
    // A retained hole does not consume the admission bound.
    try ring.push(6, try a.dupe(u8, "e"));
    try ring.acknowledgeRange(2, 2, 1, 1, 6);
    try std.testing.expectEqual(@as(u64, 3), ring.reclaimed_through);
    // A later proven range can never leap the hole.
    try ring.acknowledgeRange(2, 2, 6, 6, 6);
    try std.testing.expectEqual(@as(u64, 3), ring.reclaimed_through);
    try std.testing.expectEqual(@as(u64, 6), ring.highest_acknowledged);
    try std.testing.expectEqual(@as(usize, 2), ring.items.items.len);
    // Filling the hole advances the contiguous watermark; duplicates are
    // idempotent and never retire a missing position twice.
    try ring.acknowledgeRange(2, 2, 4, 5, 6);
    try std.testing.expectEqual(@as(u64, 6), ring.reclaimed_through);
    try std.testing.expectEqual(@as(usize, 0), ring.items.items.len);
    try ring.acknowledgeRange(2, 2, 2, 6, 6);
    try std.testing.expectEqual(@as(u64, 6), ring.reclaimed_through);
    try std.testing.expectEqual(@as(usize, 0), ring.items.items.len);
}
test "live ring retains caller ownership on allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ring = LiveRing{ .allocator = failing.allocator() };
    defer ring.deinit();
    // Allocate the fixture outside the fault allocator so its first call is
    // the ring's append; ownership remains with the caller on failure.
    const json = try std.testing.allocator.dupe(u8, "owned");
    defer std.testing.allocator.free(json);
    try std.testing.expectError(error.OutOfMemory, ring.push(1, json));
    try std.testing.expectEqualStrings("owned", json);
    try std.testing.expectEqual(@as(usize, 0), ring.bytes);
}
test "ring push retains caller ownership when allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ring = Ring{ .allocator = failing.allocator() };
    defer ring.deinit();
    const json = try std.testing.allocator.dupe(u8, "owned");
    defer std.testing.allocator.free(json);
    try std.testing.expectError(error.OutOfMemory, ring.push(1, json));
    try std.testing.expectEqualStrings("owned", json);
    try std.testing.expectEqual(@as(usize, 0), ring.items.items.len);
}
test "host live thinking crosses two real task requests and merges only after join" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "thinking-fixture.txt", .data = "owned fixture" });
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var fake: ThinkingTaskFixture = .{ .io = io };
    const host = try SessionHost.init(a, io, &env, .{ .project = home, .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    defer fake.release.store(true, .release);
    try host.connection.configureProvider(.deepseek, "fake-thinking-key");
    const app = host.session.app.?;
    app.config.value.model.reasoning = .{ .map = .{ .low = "low", .high = "high" } };
    app.config.value.model.reasoning_effort = "low";
    app.runtime.model = .{ .context = &fake, .call_fn = ThinkingTaskFixture.call };
    host.refreshConnection();
    const attached = try dispatchJson(host, a, "{\"v\":4,\"id\":1,\"op\":\"attach\",\"write\":true}", 7);
    a.free(attached);
    _ = try host.startTask(.prompt, "read the fixture");
    try std.testing.expect(host.session.owner_task_active);
    try waitThinkingFlag(host, &fake.entered, true);
    const stale = try dispatchJson(host, a, "{\"v\":4,\"id\":2,\"op\":\"effort\",\"epoch\":2,\"value\":\"high\"}", 7);
    defer a.free(stale);
    try std.testing.expect(std.mem.indexOf(u8, stale, "stale_control") != null);
    const foreign = try dispatchJson(host, a, "{\"v\":4,\"id\":3,\"op\":\"cycle_effort\",\"epoch\":1}", 8);
    defer a.free(foreign);
    try std.testing.expect(std.mem.indexOf(u8, foreign, "stale_control") != null);
    try std.testing.expect(app.thinking_control.get() == null);
    const changed = try dispatchJson(host, a, "{\"v\":4,\"id\":4,\"op\":\"effort\",\"epoch\":1,\"value\":\"high\"}", 7);
    defer a.free(changed);
    try std.testing.expect(std.mem.indexOf(u8, changed, "\"ok\":true") != null);
    try std.testing.expectEqualStrings("high", app.thinking_control.get().?.reasoning_effort.?);
    try std.testing.expectEqualStrings("low", app.config.value.model.reasoning_effort.?);
    fake.release.store(true, .release);
    // The bridge is bounded at 64 events; this two-round fixture emits far fewer.
    // Do not pump here: retain the genuine completed but unjoined task.
    try waitThinkingFlag(host, &host.task.?.job.done, false);
    try std.testing.expect(!app.runtime.busy.load(.acquire));
    try std.testing.expect(host.session.owner_task_active);
    try std.testing.expect(fake.old_after_release.load(.acquire));
    try std.testing.expect(fake.second_new.load(.acquire));
    try std.testing.expect(fake.read_ok.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), fake.calls.load(.acquire));
    host.events.max_count = 0;
    host.pump(0);
    try std.testing.expect(host.task != null and host.task.?.joined);
    const late = try dispatchJson(host, a, "{\"v\":4,\"id\":5,\"op\":\"effort\",\"epoch\":1,\"value\":\"high\"}", 7);
    defer a.free(late);
    try std.testing.expect(std.mem.indexOf(u8, late, "\"ok\":true") != null);
    try std.testing.expectEqualStrings("low", app.config.value.model.reasoning_effort.?);
    try std.testing.expectEqualStrings("high", app.thinking_control.get().?.reasoning_effort.?);
    host.inbox.pause();
    _ = try host.inbox.enqueue(a, .follow_up, "follow up");
    host.events.max_count = 1024;
    host.pump(0);
    try std.testing.expect(host.task == null and !host.session.owner_task_active);
    try std.testing.expect(app.thinking_control.get() == null);
    try std.testing.expectEqualStrings("high", app.config.value.model.reasoning_effort.?);
    try std.testing.expectEqual(@as(usize, 1), host.inbox.snapshot().follow_up);
    try host.ensureIdle();
    const bytes = try host.session.resume_lease.?.load(&host.session.project_root);
    defer a.free(bytes);
    const envelope = try @import("resume_codec.zig").inspect(a, bytes, host.session.session_id);
    try std.testing.expectEqual(@as(?@import("../presentation.zig").ReasoningEffort, .high), envelope.selection.effort);
}
test "host cancellation joins actual future and releases thinking owner" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var fake: ThinkingTaskFixture = .{ .io = io };
    const host = try SessionHost.init(a, io, &env, .{ .project = home, .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    defer fake.release.store(true, .release);
    try host.connection.configureProvider(.deepseek, "fake-cancel-key");
    const app = host.session.app.?;
    app.config.value.model.reasoning = .{ .map = .{ .low = "low", .high = "high" } };
    app.config.value.model.reasoning_effort = "low";
    app.runtime.model = .{ .context = &fake, .call_fn = ThinkingTaskFixture.call };
    _ = try host.startTask(.prompt, "cancel this request");
    try waitThinkingFlag(host, &fake.entered, true);
    try host.session.connection().setEffort(.high);
    host.cancel.cancel();
    try waitThinkingFlag(host, &host.task.?.job.done, false);
    host.pump(0);
    try std.testing.expect(host.task == null);
    try std.testing.expect(!host.session.owner_task_active);
    try std.testing.expect(app.thinking_control.get() == null);
    try std.testing.expectEqualStrings("high", app.config.value.model.reasoning_effort.?);
    try std.testing.expectEqual(@as(u32, 1), fake.calls.load(.acquire));
}
test "background completion retains exact id across backpressure and acknowledgement" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buffer);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path_buffer[0..n]);
    const host = try SessionHost.init(a, io, &env, .{ .project = path_buffer[0..n], .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    host.controller = .{ .epoch = 1, .connection = 7 };
    var source: BackgroundFixture = .{
        .first = .{ .id = background_status.Id.from("first"), .command = background_status.Command.from("one"), .result = .failed, .duration_ms = 42, .failure = .exit, .exit_code = 2 },
        .second = .{ .id = background_status.Id.from("second"), .command = background_status.Command.from("two"), .result = .success, .duration_ms = 1 },
    };
    host.events.max_count = 0;
    try std.testing.expectEqual(SessionHost.MemoryAdmission.blocked, host.admitBackgroundCompletion(&source));
    try std.testing.expect(source.taken == null and source.first_pending and source.second_pending);
    try std.testing.expectEqual(@as(u64, 1), host.next_seq);
    host.events.max_count = 1;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    host.allocator = failing.allocator();
    const allocation = host.admitBackgroundCompletion(&source);
    host.allocator = a;
    try std.testing.expectEqual(SessionHost.MemoryAdmission.unavailable, allocation);
    try std.testing.expect(source.taken == null and source.first_pending and source.second_pending);
    try std.testing.expectEqual(@as(u64, 1), host.next_seq);
    var ring_failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    host.events.allocator = ring_failing.allocator();
    const ring_allocation = host.admitBackgroundCompletion(&source);
    host.events.allocator = a;
    try std.testing.expectEqual(SessionHost.MemoryAdmission.unavailable, ring_allocation);
    try std.testing.expect(source.taken == null and source.first_pending and source.second_pending);
    try std.testing.expectEqual(@as(u64, 1), host.next_seq);
    source.switch_on_peek = true;
    try std.testing.expectEqual(SessionHost.MemoryAdmission.admitted, host.admitBackgroundCompletion(&source));
    const taken = source.taken.?;
    try std.testing.expectEqualStrings("first", taken.slice());
    try std.testing.expect(source.head_at_take_was_second);
    try std.testing.expect(!source.first_pending and source.second_pending);
    try std.testing.expectEqualStrings("second", source.peekBackgroundCompletion().?.id.slice());
    try std.testing.expect(!SessionHost.canonicalForHistory(.{ .background_completed = source.first }));
    try std.testing.expectEqual(@as(usize, 0), host.history.items.items.len);
    const page = (try host.watchEvents(a, 1, 1, 0)).?;
    defer a.free(page.frame);
    try std.testing.expect(std.mem.indexOf(u8, page.frame, "\"background_completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page.frame, "\"command\":\"one\"") != null);
    try host.watchOffered(1, page.through);
    try std.testing.expectError(error.StaleControl, host.watchAcknowledge(2, page.through));
    _ = try host.watchAcknowledge(1, page.through);
    try std.testing.expectEqual(@as(usize, 0), host.events.items.items.len);
    try std.testing.expectEqual(SessionHost.MemoryAdmission.admitted, host.admitBackgroundCompletion(&source));
    try std.testing.expectEqualStrings("second", source.taken.?.slice());
    try std.testing.expect(!source.second_pending);
    const second_page = (try host.watchEvents(a, 1, 1, page.through)).?;
    defer a.free(second_page.frame);
    try std.testing.expect(std.mem.indexOf(u8, second_page.frame, "\"command\":\"two\"") != null);
}
test "memory completions remain ordered in one watch page without affecting primary state" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buffer);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path_buffer[0..n]);
    const host = try SessionHost.init(a, io, &env, .{ .project = path_buffer[0..n], .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    host.controller = .{ .epoch = 1, .connection = 7 };
    host.phase = .calling_model;
    host.last_terminal = .{ .status = .paused, .detail = error.RoundLimit };
    host.setPending(44, "bash", "approval detail", false);
    host.observe(.{ .text = "partial body" }, false, true);
    host.observe(.{ .reasoning = "partial reasoning" }, false, true);
    const prior_seq = host.next_seq - 1;
    try host.watchOffered(1, prior_seq);
    try std.testing.expectEqual(prior_seq, try host.watchResume(1, prior_seq));
    const history_count = host.history.items.items.len;
    const model_count: ?usize = if (host.session.app) |app| app.runtime.messages().len else null;

    // A joined fixture job lets reapTask exercise its real finished ordering
    // without a worker or network. The host owns both allocations on all paths.
    const job = try a.create(task.Job);
    const prompt = a.dupe(u8, "") catch |err| {
        a.destroy(job);
        return err;
    };
    job.* = .{ .runtime = undefined, .cancel = &host.cancel, .prompt = prompt };
    host.task = .{ .job = job, .future = undefined, .joined = true, .id = 91, .kind = .prompt, .prompt = prompt };
    const memory = @import("../core/memory_status.zig");
    var first: memory.Terminal = .{ .id = 0, .result = .saved, .saved_count = 1 };
    first.summary.append("first");
    var second: memory.Terminal = .{ .id = 0, .result = .failed, .failure = .storage };
    second.summary.append("second");
    const values = [_]memory.Terminal{ first, second };
    var source: MemoryQueueFixture = .{ .values = &values };
    host.pumpFrom(0, &source);
    // Neither queued completion can interrupt the active assistant draft.
    try std.testing.expectEqual(@as(usize, 0), source.cursor);
    try std.testing.expectEqualStrings("partial body", host.partial_text.buf.items);
    try std.testing.expectEqualStrings("partial reasoning", host.partial_reasoning.buf.items);
    try std.testing.expectEqual(@as(?r.State, .calling_model), host.phase);
    try std.testing.expectEqual(r.Status.paused, host.last_terminal.?.status);
    try std.testing.expectEqual(@as(u64, 91), host.task.?.id);
    try std.testing.expectEqual(@as(?u64, 44), host.pending_permission);
    const queue = host.inbox.snapshot();
    var previews: [protocol.max_previews]protocol.QueuePreview = undefined;
    try std.testing.expect(host.snapshotFor(7, &queue, &previews).busy);
    try std.testing.expect((try host.watchEvents(a, 1, 1, prior_seq)) == null);
    // Now the actual reaper publishes the primary terminal before both FIFO
    // results, and a single watch poll still returns every ordered result.
    job.terminal = .{ .status = .success };
    job.done.store(true, .release);
    host.pumpFrom(0, &source);
    try std.testing.expectEqual(@as(usize, 2), source.cursor);
    const page = (try host.watchEvents(a, 1, 1, prior_seq)).?;
    defer a.free(page.frame);
    var doc = try std.json.parseFromSlice(std.json.Value, a, page.frame, .{});
    defer doc.deinit();
    const rows = doc.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("finished", rows[0].object.get("t").?.string);
    try std.testing.expectEqualStrings("memory_completed", rows[1].object.get("t").?.string);
    try std.testing.expectEqualStrings("memory_completed", rows[2].object.get("t").?.string);
    try std.testing.expectEqualStrings("first", rows[1].object.get("summary").?.string);
    try std.testing.expectEqualStrings("second", rows[2].object.get("summary").?.string);
    for (rows, 0..) |row, i| try std.testing.expectEqual(@as(i64, @intCast(prior_seq + i + 1)), row.object.get("seq").?.integer);
    try std.testing.expectEqual(@as(i64, 0), rows[1].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, 0), rows[2].object.get("id").?.integer);
    try std.testing.expect(!SessionHost.canonicalForHistory(.{ .memory_completed = first }));
    // The primary finished row is retained as usual; neither Memory row is.
    try std.testing.expectEqual(history_count + 1, host.history.items.items.len);
    if (model_count) |count| try std.testing.expectEqual(count, host.session.app.?.runtime.messages().len);
    try std.testing.expect(host.task == null);
    try std.testing.expectEqual(r.Status.success, host.last_terminal.?.status);
    try std.testing.expectEqual(prior_seq, try host.watchResume(1, prior_seq));

    // Defense in depth: admission itself never mutates drafts or approvals,
    // even if a caller supplies preexisting state at an idle boundary.
    host.partial_text.append("retained body");
    host.partial_reasoning.append("retained reasoning");
    host.setPending(45, "bash", "retained permission", false);
    var another: MemoryQueueFixture = .{ .values = values[0..1] };
    try std.testing.expectEqual(SessionHost.MemoryAdmission.admitted, host.admitMemoryCompletion(&another));
    try std.testing.expectEqualStrings("retained body", host.partial_text.buf.items);
    try std.testing.expectEqualStrings("retained reasoning", host.partial_reasoning.buf.items);
    try std.testing.expectEqual(@as(?u64, 45), host.pending_permission);
    try std.testing.expectEqualStrings("retained permission", host.pending_desc.?);
    try std.testing.expectEqual(r.Status.success, host.last_terminal.?.status);
    try std.testing.expectEqual(history_count + 1, host.history.items.items.len);
    try std.testing.expectEqual(prior_seq, try host.watchResume(1, prior_seq));
    try std.testing.expect(host.fatal == null);
}
test "memory completion retains FIFO head on ring full and encoding or ring allocation OOM" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buffer);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path_buffer[0..n]);
    const host = try SessionHost.init(a, io, &env, .{ .project = path_buffer[0..n], .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    host.controller = .{ .epoch = 1, .connection = 7 };
    host.events.max_count = 1;
    const memory = @import("../core/memory_status.zig");
    const values = [_]memory.Terminal{ .{ .id = 0, .result = .saved }, .{ .id = 0, .result = .skipped } };
    var source: MemoryQueueFixture = .{ .values = &values };

    var encode_oom = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    host.allocator = encode_oom.allocator();
    host.pumpFrom(0, &source);
    host.allocator = a;
    try std.testing.expectEqual(@as(usize, 0), source.cursor);
    try std.testing.expectEqual(@as(u64, 1), host.next_seq);
    try std.testing.expect(host.fatal == null);

    var ring_oom = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    host.events.allocator = ring_oom.allocator();
    host.pumpFrom(0, &source);
    host.events.allocator = a;
    try std.testing.expectEqual(@as(usize, 0), source.cursor);
    try std.testing.expectEqual(@as(u64, 1), host.next_seq);
    try std.testing.expect(host.fatal == null);

    host.pumpFrom(0, &source);
    try std.testing.expectEqual(@as(usize, 1), source.cursor);
    try std.testing.expectEqual(@as(u64, 2), host.next_seq);
    host.pumpFrom(0, &source);
    try std.testing.expectEqual(@as(usize, 1), source.cursor);
    try std.testing.expectEqual(@as(u64, 2), host.next_seq);
    try std.testing.expect(host.fatal == null);
    const first_page = (try host.watchEvents(a, 1, 1, 0)).?;
    defer a.free(first_page.frame);
    try std.testing.expectEqual(@as(u64, 1), first_page.through);
    try host.watchOffered(1, first_page.through);
    try std.testing.expectEqual(@as(u64, 1), try host.watchResume(1, 1));
    _ = try host.watchAcknowledge(1, 1);
    host.pumpFrom(0, &source);
    try std.testing.expectEqual(@as(usize, 2), source.cursor);
    try std.testing.expectEqual(@as(u64, 3), host.next_seq);
    try std.testing.expectEqual(@as(u64, 1), try host.watchResume(1, 1));
    const second_page = (try host.watchEvents(a, 1, 1, 1)).?;
    defer a.free(second_page.frame);
    try std.testing.expect(std.mem.indexOf(u8, second_page.frame, "\"result\":\"skipped\"") != null);
    try std.testing.expectEqual(@as(u64, 2), second_page.through);
    try host.watchOffered(1, 2);
    _ = try host.watchAcknowledge(1, 2);
    host.pumpFrom(0, &source);
    try std.testing.expectEqual(@as(usize, 0), host.events.items.items.len);
    try std.testing.expectEqual(@as(u64, 3), host.next_seq);
    try std.testing.expect((try host.watchEvents(a, 1, 1, 2)) == null);
    try std.testing.expect(host.fatal == null);
}
test "idle refresh publishes restored context after login without requests" {
    const Spy = struct {
        calls: usize = 0,
        fn call(raw: *anyopaque, _: std.mem.Allocator, _: p.Request, _: p.ModelSink) !p.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return error.UnexpectedModelCall;
        }
        fn expectSnapshot(host: *SessionHost, expected: r.ContextSnapshot) !void {
            const a = std.testing.allocator;
            const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":9,\"op\":\"snapshot\"}", 7);
            defer a.free(frame);
            var doc = try parseJson(a, frame);
            defer doc.deinit();
            try std.testing.expect(doc.value.object.get("ok").?.bool);
            const snapshot = doc.value.object.get("snapshot").?.object;
            try std.testing.expect(!snapshot.get("busy").?.bool);
            const context = snapshot.get("ctx").?.object;
            try std.testing.expectEqual(@as(i64, @intCast(expected.tokens)), context.get("tokens").?.integer);
            try std.testing.expectEqual(@as(i64, @intCast(expected.limit)), context.get("limit").?.integer);
            try std.testing.expectEqual(expected.known, context.get("known").?.bool);
        }
    };
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]?u64{ 77, 0, null }) |reported| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [4096]u8 = undefined;
        const home = path[0..try tmp.dir.realPath(io, &path)];
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("HOME", home);
        try env.put("CONTEXT_FIXTURE_KEY", "fake-source-key");
        try tmp.dir.createDir(io, ".thin", .default_dir);
        try tmp.dir.writeFile(io, .{ .sub_path = ".thin/config.json", .data =
            \\{"llm":{"default":"archive/saved","providers":{"archive":{"base_url":"https://archive.invalid/v1","api_key_env":"CONTEXT_FIXTURE_KEY","models":{"saved":{"protocol":"chat","context_tokens":131072}}}}},"limits":{"low_price_input":false}}
        });
        const id = try ids.generate(io);
        {
            var source = try Session.initWithOptions(a, io, &env, home, .{}, .{ .session_id = id });
            defer source.deinit();
            const app = source.app.?;
            try app.runtime.restoreCheckpoint(.{
                .system = "archived system",
                .selector = app.runtime.selector,
                .estimator = .{},
                .last_context_tokens = reported,
                .permission_id = 19,
                .messages = &.{
                    .{ .role = .user, .blocks = &.{.{ .text = "saved question" }} },
                    .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "old-tool", .name = "write_file", .arguments = "{\"path\":\"must-not-run.txt\",\"content\":\"no\"}" } }} },
                    .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "old-tool", .text = "old result" } }} },
                    .{ .role = .assistant, .blocks = &.{.{ .text = "saved answer" }} },
                },
            });
            try std.testing.expect(try source.saveOnExit());
        }
        try env.put("CONTEXT_FIXTURE_KEY", "");
        const host = try SessionHost.init(a, io, &env, .{ .project = home, .id = id, .@"resume" = id, .owner = .foreground });
        defer host.deinit();
        try std.testing.expect(host.session.app == null and host.session.loaded_checkpoint != null);
        try std.testing.expectError(error.Unavailable, host.startTask(.prompt, "not sent"));
        const attached = try dispatchJson(host, a, "{\"v\":4,\"id\":1,\"op\":\"attach\",\"write\":true}", 7);
        defer a.free(attached);
        try std.testing.expect(std.mem.indexOf(u8, attached, "\"epoch\":1") != null);
        const expected = r.ContextSnapshot{ .tokens = reported orelse 0, .limit = 131072, .known = reported != null };
        try Spy.expectSnapshot(host, expected);
        const history_count = host.history.items.items.len;
        try std.testing.expect(history_count != 0);
        // Refresh without an App must republish the pending display projection.
        host.context = null;
        host.refreshConnection();
        try Spy.expectSnapshot(host, expected);
        // Simulate an older cached host value to prove login really refreshes it.
        host.context = .{ .tokens = 999, .limit = 1 };
        const login = try dispatchJson(host, a, "{\"v\":4,\"id\":2,\"op\":\"login\",\"epoch\":1,\"key\":\"fake-login-key\"}", 7);
        defer a.free(login);
        try std.testing.expect(std.mem.indexOf(u8, login, "\"ok\":true") != null);
        const app = host.session.app.?;
        try std.testing.expect(host.session.loaded_checkpoint == null);
        try Spy.expectSnapshot(host, expected);
        try std.testing.expectEqual(history_count, host.history.items.items.len);
        try std.testing.expectEqual(@as(usize, 4), app.runtime.messages().len);
        try std.testing.expectEqualStrings("saved answer", app.runtime.messages()[3].blocks[0].text);
        try std.testing.expectEqual(@as(u64, 0), app.runtime.permission_id);
        try std.testing.expect(!app.journal.started and app.client.last_request_finish == null);
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "must-not-run.txt", .{}));
        try std.testing.expectEqual(@as(u64, 0), host.task_seq);
        try std.testing.expect(host.task == null and host.session.metadata_job == null);

        var spy: Spy = .{};
        const original_model = app.runtime.model;
        defer app.runtime.model = original_model;
        app.runtime.model = .{ .context = &spy, .call_fn = Spy.call };
        // Model usage and the corresponding bridge event advance independently
        // of Session.initial_context, which remains the login-time value.
        app.runtime.last_context_tokens = 246;
        host.observe(.{ .context_snapshot = app.runtime.contextSnapshot() }, false, true);
        try std.testing.expectEqualDeep(expected, host.session.initial_context.?);
        const latest = r.ContextSnapshot{ .tokens = 246, .limit = 131072 };
        try Spy.expectSnapshot(host, latest);
        // Disabling an already-disabled image model is an unrelated settings
        // no-op: it does not update Session.initial_context itself.
        const setting = try dispatchJson(host, a, "{\"v\":4,\"id\":3,\"op\":\"image_model\",\"epoch\":1,\"off\":true}", 7);
        defer a.free(setting);
        try std.testing.expect(std.mem.indexOf(u8, setting, "\"ok\":true") != null);
        try std.testing.expectEqualDeep(expected, host.session.initial_context.?);
        try Spy.expectSnapshot(host, latest);
        try std.testing.expectEqual(@as(usize, 0), spy.calls);
        try std.testing.expectEqual(@as(u64, 0), host.task_seq);
        try std.testing.expect(!app.journal.started and app.client.last_request_finish == null);
    }
}
test "connection refresh refuses an unjoined or busy runtime" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    const host = try SessionHost.init(a, io, &env, .{ .project = home, .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    try host.connection.configureProvider(.deepseek, "fake-idle-guard-key");
    const app = host.session.app.?;
    app.runtime.last_context_tokens = 246;
    const sentinel = r.ContextSnapshot{ .tokens = 7, .limit = 1 };
    host.context = sentinel;
    {
        // No worker is launched: this only represents the unjoined interval,
        // including the period before Runtime.busy is set.
        host.task = .{ .job = undefined, .future = undefined, .id = 1, .kind = .prompt, .prompt = undefined };
        defer host.task = null;
        try std.testing.expectError(error.Busy, host.ensureIdle());
        host.refreshConnection();
        try std.testing.expectEqualDeep(sentinel, host.context.?);
    }
    {
        app.runtime.busy.store(true, .release);
        defer app.runtime.busy.store(false, .release);
        try std.testing.expectError(error.Busy, host.ensureIdle());
        host.refreshConnection();
        try std.testing.expectEqualDeep(sentinel, host.context.?);
    }
    host.refreshConnection();
    try std.testing.expectEqualDeep(app.runtime.contextSnapshot(), host.context.?);
}
test "metadata owner idle is independent of client wait field" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    const host = try SessionHost.init(a, io, &env, .{ .project = home, .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    const attached = try dispatchJson(host, a, "{\"v\":4,\"id\":1,\"op\":\"attach\",\"write\":true}", 7);
    defer a.free(attached);
    try std.testing.expect(std.mem.indexOf(u8, attached, "\"epoch\":1") != null);

    var spy = MetadataOwnerIdleSpy{};
    const old_context = host.connection.context;
    const old_poll = host.connection.poll_models_fn;
    defer {
        host.connection.context = old_context;
        host.connection.poll_models_fn = old_poll;
    }
    host.connection.context = &spy;
    host.connection.poll_models_fn = MetadataOwnerIdleSpy.poll;
    for ([_][]const u8{
        "{\"v\":4,\"id\":2,\"op\":\"poll_metadata\",\"wait\":false}",
        "{\"v\":4,\"id\":3,\"op\":\"poll_metadata\"}",
        "{\"v\":4,\"id\":4,\"op\":\"poll_metadata\",\"wait\":true}",
    }) |json| {
        const frame = try dispatchJson(host, a, json, 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
    }
    try std.testing.expectEqual(@as(usize, 3), spy.count);
    try std.testing.expectEqual([3]bool{ true, true, true }, spy.values);
}
test "metadata owner idle rejects malformed wait and pending terminal" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    const host = try SessionHost.init(a, io, &env, .{ .project = home, .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    const attached = try dispatchJson(host, a, "{\"v\":4,\"id\":1,\"op\":\"attach\",\"write\":true}", 7);
    defer a.free(attached);
    try std.testing.expect(std.mem.indexOf(u8, attached, "\"epoch\":1") != null);

    var spy = MetadataOwnerIdleSpy{};
    const old_context = host.connection.context;
    const old_poll = host.connection.poll_models_fn;
    defer {
        host.connection.context = old_context;
        host.connection.poll_models_fn = old_poll;
    }
    host.connection.context = &spy;
    host.connection.poll_models_fn = MetadataOwnerIdleSpy.poll;
    const malformed = try dispatchJson(host, a, "{\"v\":4,\"id\":2,\"op\":\"poll_metadata\",\"wait\":\"true\"}", 7);
    defer a.free(malformed);
    try std.testing.expect(std.mem.indexOf(u8, malformed, "\"ok\":false") != null);
    const stale = try dispatchJson(host, a, "{\"v\":4,\"id\":3,\"op\":\"poll_metadata\",\"wait\":true}", 8);
    defer a.free(stale);
    try std.testing.expect(std.mem.indexOf(u8, stale, "\"ok\":false") != null);
    host.pending_terminal = .{ .terminal = .{ .status = .success }, .json = try a.dupe(u8, "pending") };
    defer {
        if (host.pending_terminal) |pending| a.free(pending.json);
        host.pending_terminal = null;
    }
    const busy = try dispatchJson(host, a, "{\"v\":4,\"id\":4,\"op\":\"poll_metadata\",\"wait\":true}", 7);
    defer a.free(busy);
    try std.testing.expect(std.mem.indexOf(u8, busy, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, busy, "busy") != null);
    try std.testing.expectEqual(@as(usize, 0), spy.count);
}
test "metadata owner idle publishes real session capabilities on nonblocking polls" {
    const Fixture = struct {
        var official_calls: std.atomic.Value(usize) = .init(0);
        var dev_calls: std.atomic.Value(usize) = .init(0);
        fn official(a: std.mem.Allocator, _: Io, id: providers.Id, key: ?[]const u8) !@import("model_metadata.zig").Listing {
            _ = official_calls.fetchAdd(1, .monotonic);
            if (id != .deepseek or key == null or !std.mem.eql(u8, key.?, "fake-metadata-key")) return error.InvalidFixture;
            return @import("model_metadata.zig").parseListing(a, "{\"data\":[{\"id\":\"deepseek-flash\",\"effort\":{\"supported_levels\":[\"low\",\"high\",\"max\"]}}]}", id);
        }
        fn dev(_: std.mem.Allocator, _: Io) !@import("model_metadata.zig").Listing {
            _ = dev_calls.fetchAdd(1, .monotonic);
            return .{ .dev_done = true };
        }
    };
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const home = path[0..try tmp.dir.realPath(io, &path)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    {
        var store = try @import("auth_store.zig").Store.open(a, io, home);
        defer store.deinit();
        var initial = try store.loadOrInitialize();
        defer cfg.release(&initial);
        var config = try cfg.parse(a, "{\"llm\":{\"default\":\"deepseek/deepseek-flash\",\"reasoning_effort\":\"medium\",\"providers\":{\"deepseek\":{\"base_url\":\"https://api.deepseek.com\",\"kind\":\"deepseek\",\"chat_max_tokens\":true}}}}");
        defer cfg.release(&config);
        try store.save(config.value);
    }
    Fixture.official_calls.store(0, .monotonic);
    Fixture.dev_calls.store(0, .monotonic);
    const host = try SessionHost.init(a, io, &env, .{ .project = home, .id = try ids.generate(io), .owner = .foreground, .auto_refresh_models = true });
    defer host.deinit();
    host.session.metadata_fetch = Fixture.official;
    host.session.metadata_dev_fetch = Fixture.dev;
    const attached = try dispatchJson(host, a, "{\"v\":4,\"id\":1,\"op\":\"attach\",\"write\":true}", 7);
    defer a.free(attached);
    try std.testing.expect(std.mem.indexOf(u8, attached, "\"epoch\":1") != null);
    try host.connection.configureProvider(.deepseek, "fake-metadata-key");
    host.refreshConnection();
    try std.testing.expect(host.session.initial_default_pending);
    const poll = "{\"v\":4,\"id\":2,\"op\":\"poll_metadata\",\"wait\":false}";
    const first = try dispatchJson(host, a, poll, 7);
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"ok\":true") != null);
    try std.testing.expect(host.session.metadata_job != null);
    const deadline = Io.Clock.awake.now(io).toMilliseconds() + 5000;
    while (host.session.metadata_job != null or host.session.initial_default_pending) {
        if (Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.FixtureCompletionTimeout;
        try Io.sleep(io, .fromMilliseconds(1), .awake);
        const frame = try dispatchJson(host, a, poll, 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
    }
    const state = host.connection.current();
    try std.testing.expectEqual(@as(usize, 1), Fixture.official_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), Fixture.dev_calls.load(.monotonic));
    try std.testing.expectEqual(@as(u8, 0x55), state.effort_levels.mask);
    try std.testing.expectEqual(activity.ReasoningEffort.high, state.reasoning_effort);
    try std.testing.expectEqualStrings("high", host.session.app.?.config.value.model.reasoning_effort.?);
    try std.testing.expect(host.session.app.?.config.value.model.reasoning != null);
    try std.testing.expect(host.task == null);
    try std.testing.expectEqual(@as(usize, 0), host.history.items.items.len);
    try std.testing.expect(!host.session.app.?.journal.started);
    const cycle = try dispatchJson(host, a, "{\"v\":4,\"id\":3,\"op\":\"cycle_effort\",\"epoch\":1}", 7);
    defer a.free(cycle);
    try std.testing.expect(std.mem.indexOf(u8, cycle, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, cycle, "\"value\":\"max\"") != null);
    try std.testing.expectEqual(activity.ReasoningEffort.max, host.connection.current().reasoning_effort);
    try std.testing.expect(host.task == null);
    try std.testing.expect(!host.session.app.?.journal.started);
}
test "codex control rejects invalid and stale actions without starting login" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path[0..n]);
    const host = try SessionHost.init(a, io, &env, .{ .project = path[0..n], .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    const attach = try dispatchJson(host, a, "{\"v\":4,\"id\":1,\"op\":\"attach\"}", 7);
    defer a.free(attach);
    const before = host.watchStamp();
    const invalid = try dispatchJson(host, a, "{\"v\":4,\"id\":2,\"op\":\"codex_login\",\"epoch\":1,\"action\":\"bogus\",\"generation\":0}", 7);
    defer a.free(invalid);
    try std.testing.expect(std.mem.indexOf(u8, invalid, "\"ok\":false") != null);
    const stale = try dispatchJson(host, a, "{\"v\":4,\"id\":3,\"op\":\"codex_login\",\"epoch\":1,\"action\":\"cancel\",\"generation\":99}", 7);
    defer a.free(stale);
    try std.testing.expect(std.mem.indexOf(u8, stale, "\"ok\":false") != null);
    const after = host.watchStamp();
    // The generic view revision advances even for rejected mutations, not just login changes.
    try std.testing.expectEqual(before.revision + 2, after.revision);
    try std.testing.expect(std.meta.eql(before.codex, after.codex));
    try std.testing.expectEqual(before.queue_revision, after.queue_revision);
    try std.testing.expectEqual(before.task, after.task);
    try std.testing.expectEqual(@as(u64, 0), after.codex.generation);
    try std.testing.expectEqual(@as(u64, 0), after.task);
    const frame = try host.watchSnapshot(a, 4, 1);
    defer a.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"codex_login\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "access_token") == null);
}
test "watch coverage, bounded admission and epoch bound acknowledgements" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buffer);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path_buffer[0..n]);
    const host = try SessionHost.init(a, io, &env, .{ .project = path_buffer[0..n], .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    try std.testing.expectError(error.StaleControl, host.watchOwner(1));
    const attached = try dispatchJson(host, a, "{\"v\":4,\"id\":1,\"op\":\"attach\"}", 7);
    defer a.free(attached);
    try std.testing.expectEqual(@as(u64, 7), try host.watchOwner(1));
    _ = host.noteSubmittedUser("first canonical input");
    const high = host.watchStamp().sequence;
    const snapshot = try host.watchSnapshot(a, 9, 1);
    defer a.free(snapshot);
    const baseline = try host.watchBaseline(a, 9, 1);
    defer a.free(baseline);
    var snap_doc = try std.json.parseFromSlice(std.json.Value, a, snapshot, .{});
    defer snap_doc.deinit();
    var base_doc = try std.json.parseFromSlice(std.json.Value, a, baseline, .{});
    defer base_doc.deinit();
    try std.testing.expectEqual(@as(i64, @intCast(high)), snap_doc.value.object.get("through").?.integer);
    try std.testing.expectEqual(@as(i64, 0), base_doc.value.object.get("through").?.integer);
    try std.testing.expectEqualStrings("baseline", base_doc.value.object.get("stream").?.string);
    const before_text = host.watchStamp();
    host.observe(.{ .text = "after baseline" }, false, true);
    try std.testing.expect(before_text.eql(host.watchStamp()));
    const page = (try host.watchEvents(a, 9, 1, high)).?;
    defer a.free(page.frame);
    try std.testing.expectEqual(high + 1, page.through);
    try std.testing.expect(std.mem.indexOf(u8, baseline, "after baseline") == null);
    try std.testing.expect(std.mem.indexOf(u8, page.frame, "after baseline") != null);
    // History-only positions are covered, not diagnosed as missing events.
    _ = host.noteSubmittedUser("second canonical input");
    host.observe(.{ .text = "second live delta" }, false, true);
    const next = (try host.watchEvents(a, 9, 1, page.through)).?;
    defer a.free(next.frame);
    var next_doc = try std.json.parseFromSlice(std.json.Value, a, next.frame, .{});
    defer next_doc.deinit();
    // The ordered union puts the history-only direct submit at position 3
    // before the live delta at position 4 instead of appending it later.
    const next_events = next_doc.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), next_events.len);
    try std.testing.expectEqual(@as(i64, 3), next_events[0].object.get("seq").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, next_events[0].object.get("v").?.string, "second canonical input") != null);
    try std.testing.expectEqual(@as(i64, 4), next_events[1].object.get("seq").?.integer);
    try std.testing.expectEqual(false, next_doc.value.object.get("incomplete").?.bool);
    try std.testing.expectEqual(high + 3, next.through);
    try std.testing.expect((try host.watchEvents(a, 9, 1, next.through)) == null);
    host.events.max_count = 2;
    const producer = host.bridge.host();
    try producer.emit_fn(producer.context, .{ .text = "held中" }, &host.cancel);
    host.pump(0);
    try std.testing.expect(host.pending_event != null);
    try std.testing.expectEqual(@as(usize, 2), host.events.items.items.len);
    try std.testing.expectEqual(high + 3, host.watchStamp().sequence);
    try host.watchOffered(1, next.through);
    const future = try dispatchJson(host, a, "{\"v\":4,\"id\":4,\"op\":\"ack\",\"epoch\":1,\"sequence\":999}", 7);
    defer a.free(future);
    try std.testing.expect(std.mem.indexOf(u8, future, "invalid_input") != null);
    const stale = try dispatchJson(host, a, "{\"v\":4,\"id\":5,\"op\":\"ack\",\"epoch\":2,\"sequence\":1}", 7);
    defer a.free(stale);
    try std.testing.expect(std.mem.indexOf(u8, stale, "stale_control") != null);
    const ack = try dispatchJson(host, a, "{\"v\":4,\"id\":6,\"op\":\"ack\",\"epoch\":1,\"sequence\":2}", 7);
    defer a.free(ack);
    try std.testing.expect(std.mem.indexOf(u8, ack, "\"ok\":true") != null);
    host.pump(0);
    try std.testing.expect(host.pending_event == null);
    try std.testing.expectEqual(high + 4, host.watchStamp().sequence);
    try std.testing.expectEqualStrings("held中", host.partial_text.buf.items["after baselinesecond live delta".len..]);
    try std.testing.expectEqual(@as(u64, 2), try host.watchResume(1, 2));
    try std.testing.expectError(error.InvalidSequence, host.watchResume(1, 999));
    const resumed_page = (try host.watchEvents(a, 9, 1, 2)).?;
    defer a.free(resumed_page.frame);
    try std.testing.expect(std.mem.indexOf(u8, resumed_page.frame, "held中") != null);
    try host.watchOffered(1, resumed_page.through);
    const ack_all = try std.fmt.allocPrint(a, "{{\"v\":4,\"id\":7,\"op\":\"ack\",\"epoch\":1,\"sequence\":{d}}}", .{resumed_page.through});
    defer a.free(ack_all);
    const ack_result = try dispatchJson(host, a, ack_all, 7);
    defer a.free(ack_result);
    try std.testing.expect(std.mem.indexOf(u8, ack_result, "\"ok\":true") != null);
    const before_state = host.watchStamp();
    host.observe(.{ .state = .calling_model }, false, true);
    try std.testing.expect(!before_state.eql(host.watchStamp()));
    const takeover = try dispatchJson(host, a, "{\"v\":4,\"id\":2,\"op\":\"attach\",\"takeover\":true}", 8);
    defer a.free(takeover);
    try std.testing.expectError(error.StaleControl, host.watchEvents(a, 9, 1, next.through));
    try std.testing.expectEqual(@as(u64, 8), try host.watchOwner(2));
}
test "fresh baseline and live pages form one ordered union without duplicate draft bytes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buffer);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", path_buffer[0..n]);
    const host = try SessionHost.init(a, io, &env, .{ .project = path_buffer[0..n], .id = try ids.generate(io), .owner = .foreground });
    defer host.deinit();
    const attached = try dispatchJson(host, a, "{\"v\":4,\"id\":1,\"op\":\"attach\"}", 7);
    defer a.free(attached);

    _ = host.noteSubmittedUser("hello");
    host.observe(.{ .text = "中" }, false, true);
    host.observe(.{ .text = "🙂" }, false, true);
    try std.testing.expectEqual(@as(u64, 3), host.watchStamp().sequence);

    // Nothing is acknowledged: the cutoff is 0, so no history row and no draft
    // byte belongs to the baseline; every position follows in order.
    {
        const frame = try host.watchBaseline(a, 5, 1);
        defer a.free(frame);
        var doc = try std.json.parseFromSlice(std.json.Value, a, frame, .{});
        defer doc.deinit();
        try std.testing.expectEqual(@as(usize, 0), doc.value.object.get("entries").?.array.items.len);
        try std.testing.expectEqual(false, doc.value.object.get("truncated").?.bool);
        try std.testing.expectEqual(@as(i64, 0), doc.value.object.get("through").?.integer);
    }
    {
        const page = (try host.watchEvents(a, 5, 1, 0)).?;
        defer a.free(page.frame);
        var doc = try std.json.parseFromSlice(std.json.Value, a, page.frame, .{});
        defer doc.deinit();
        const events = doc.value.object.get("events").?.array.items;
        try std.testing.expectEqual(@as(usize, 3), events.len);
        try std.testing.expectEqual(@as(i64, 1), events[0].object.get("seq").?.integer);
        try std.testing.expectEqualStrings("hello", events[0].object.get("v").?.string);
        try std.testing.expectEqual(@as(i64, 2), events[1].object.get("seq").?.integer);
        try std.testing.expectEqualStrings("中", events[1].object.get("v").?.string);
        try std.testing.expectEqual(@as(i64, 3), events[2].object.get("seq").?.integer);
        try std.testing.expectEqualStrings("🙂", events[2].object.get("v").?.string);
        try std.testing.expectEqual(false, doc.value.object.get("incomplete").?.bool);
    }
    try host.watchOffered(1, 3);
    // Retire only the history-only direct submit: the ordered cutoff is 1 even
    // though the live text is still retained.
    _ = try host.watchAcknowledgeRange(1, 1, 1);
    try std.testing.expectEqual(@as(u64, 1), host.events.reclaimed_through);
    {
        const frame = try host.watchBaseline(a, 6, 1);
        defer a.free(frame);
        var doc = try std.json.parseFromSlice(std.json.Value, a, frame, .{});
        defer doc.deinit();
        const entries = doc.value.object.get("entries").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), entries.len);
        try std.testing.expectEqualStrings("hello", entries[0].object.get("v").?.string);
        try std.testing.expectEqual(false, doc.value.object.get("truncated").?.bool);
        try std.testing.expectEqual(@as(i64, 1), doc.value.object.get("through").?.integer);
    }
    {
        const page = (try host.watchEvents(a, 6, 1, 1)).?;
        defer a.free(page.frame);
        var doc = try std.json.parseFromSlice(std.json.Value, a, page.frame, .{});
        defer doc.deinit();
        const events = doc.value.object.get("events").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), events.len);
        try std.testing.expectEqual(@as(i64, 2), events[0].object.get("seq").?.integer);
        try std.testing.expectEqual(@as(i64, 3), events[1].object.get("seq").?.integer);
        try std.testing.expectEqual(false, doc.value.object.get("incomplete").?.bool);
    }
    // Retiring the first live text delta moves the cutoff to 2; the baseline
    // then carries exactly the retired draft prefix "中" (UTF-8 safe) and the
    // retained "🙂" follows as an ordered page.
    _ = try host.watchAcknowledgeRange(1, 2, 2);
    try std.testing.expectEqual(@as(u64, 2), host.events.reclaimed_through);
    {
        const frame = try host.watchBaseline(a, 7, 1);
        defer a.free(frame);
        var doc = try std.json.parseFromSlice(std.json.Value, a, frame, .{});
        defer doc.deinit();
        const entries = doc.value.object.get("entries").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), entries.len);
        try std.testing.expectEqualStrings("hello", entries[0].object.get("v").?.string);
        try std.testing.expectEqualStrings("中", entries[1].object.get("v").?.string);
        try std.testing.expectEqual(false, doc.value.object.get("truncated").?.bool);
    }
    {
        const page = (try host.watchEvents(a, 7, 1, 2)).?;
        defer a.free(page.frame);
        var doc = try std.json.parseFromSlice(std.json.Value, a, page.frame, .{});
        defer doc.deinit();
        const events = doc.value.object.get("events").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), events.len);
        try std.testing.expectEqual(@as(i64, 3), events[0].object.get("seq").?.integer);
        try std.testing.expectEqualStrings("🙂", events[0].object.get("v").?.string);
        try std.testing.expectEqual(false, doc.value.object.get("incomplete").?.bool);
    }
    // The SAME viewer resumes from its own admitted cursor, not the server's
    // contiguous reclaimed watermark.
    try std.testing.expectEqual(@as(u64, 3), try host.watchResume(1, 3));
    try std.testing.expect((try host.watchEvents(a, 7, 1, 3)) == null);

    // This controller rendered its own direct submit locally; the ordered pages
    // consume its position without echoing the row back.
    _ = host.noteSubmittedUser("again");
    try std.testing.expectEqual(@as(u64, 4), host.watchStamp().sequence);
    host.controller.?.suppressed_history_through = 4;
    {
        const page = (try host.watchEvents(a, 8, 1, 2)).?;
        defer a.free(page.frame);
        var doc = try std.json.parseFromSlice(std.json.Value, a, page.frame, .{});
        defer doc.deinit();
        const events = doc.value.object.get("events").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), events.len);
        try std.testing.expectEqual(@as(i64, 3), events[0].object.get("seq").?.integer);
        try std.testing.expect(std.mem.indexOf(u8, page.frame, "again") == null);
        try std.testing.expectEqual(false, doc.value.object.get("incomplete").?.bool);
    }
    // A replacement controller has no local echo to suppress: its baseline and
    // pages carry the canonical row in sequence order.
    const takeover = try dispatchJson(host, a, "{\"v\":4,\"id\":2,\"op\":\"attach\",\"takeover\":true}", 8);
    defer a.free(takeover);
    try std.testing.expectEqual(@as(u64, 0), host.controller.?.suppressed_history_through);
    {
        const page = (try host.watchEvents(a, 9, 2, 2)).?;
        defer a.free(page.frame);
        var doc = try std.json.parseFromSlice(std.json.Value, a, page.frame, .{});
        defer doc.deinit();
        const events = doc.value.object.get("events").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), events.len);
        try std.testing.expectEqual(@as(i64, 3), events[0].object.get("seq").?.integer);
        try std.testing.expectEqual(@as(i64, 4), events[1].object.get("seq").?.integer);
        try std.testing.expectEqualStrings("again", events[1].object.get("v").?.string);
        try std.testing.expectEqual(false, doc.value.object.get("incomplete").?.bool);
    }
    // A position that exists nowhere any more is surfaced, never claimed exact.
    host.observe(.{ .state = .calling_model }, false, true);
    try std.testing.expectEqual(@as(u64, 5), host.watchStamp().sequence);
    try host.watchOffered(2, 5);
    _ = try host.watchAcknowledgeRange(2, 5, 5);
    try std.testing.expectEqual(@as(u64, 2), host.events.reclaimed_through);
    {
        const page = (try host.watchEvents(a, 10, 2, 2)).?;
        defer a.free(page.frame);
        var doc = try std.json.parseFromSlice(std.json.Value, a, page.frame, .{});
        defer doc.deinit();
        // seq3 is retained, seq5 was selectively retired and has no history row,
        // so the page covers 3..5 but cannot claim the missing 5.
        try std.testing.expectEqual(true, doc.value.object.get("incomplete").?.bool);
        try std.testing.expectEqual(@as(i64, 3), doc.value.object.get("events").?.array.items[0].object.get("seq").?.integer);
    }
}
test "host lifecycle: attach snapshot settings queue and rejection paths" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    const home = project;

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &env, .{ .project = project, .id = id, .owner = .foreground });
    defer host.deinit();

    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":1,\"op\":\"hello\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
        var hello = try std.json.parseFromSlice(std.json.Value, a, frame, .{});
        defer hello.deinit();
        try std.testing.expectEqual(@as(i64, protocol.version), hello.value.object.get("protocol").?.integer);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"owner\":\"foreground\"") != null);
    }
    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":2,\"op\":\"snapshot\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"busy\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"read_only\":false") != null);
    }
    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":3,\"op\":\"settings\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"effort\":null") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"available\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "api_key") == null);
    }
    // Attach assigns an epoch bound to this connection.
    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":4,\"op\":\"attach\",\"write\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"epoch\":1") != null);
    }
    // A second controller is refused without takeover.
    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":5,\"op\":\"attach\",\"write\":true}", 8);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "busy") != null);
    }
    // Another connection cannot act with the first connection's epoch.
    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":6,\"op\":\"submit\",\"epoch\":1,\"req\":10,\"kind\":\"prompt\",\"text\":\"hi\"}", 8);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "stale_control") != null);
    }
    // Queue enqueue/withdraw uses its own field name and is connection bound.
    var queued_id: u64 = 0;
    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":7,\"op\":\"enqueue\",\"epoch\":1,\"kind\":\"steering\",\"text\":\"more\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
        const at = std.mem.indexOf(u8, frame, "\"queue\":").?;
        queued_id = try std.fmt.parseInt(u64, frame[at + 8 .. std.mem.indexOfScalarPos(u8, frame, at, '}').?], 10);
    }
    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":8,\"op\":\"withdraw\",\"epoch\":1,\"queue_id\":9,\"text\":\"x\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":false") != null);
    }
    {
        const buf = try std.fmt.allocPrint(a, "{{\"v\":4,\"id\":9,\"op\":\"withdraw\",\"epoch\":1,\"queue_id\":{d}}}", .{queued_id});
        defer a.free(buf);
        const frame = try dispatchJson(host, a, buf, 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"text\":\"more\"") != null);
    }
    // Approvals for an id that is not pending are rejected by the Bridge.
    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":10,\"op\":\"approve\",\"epoch\":1,\"permission_id\":3,\"allow\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "permission_expired") != null);
    }
    // History base is the last represented sequence and includes current state.
    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":11,\"op\":\"history\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"entries\":[") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"base\":") != null);
    }
    // Disconnect revokes the controller but keeps the host usable.
    host.disconnected(7);
    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":12,\"op\":\"attach\",\"write\":true}", 8);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"epoch\":2") != null);
    }
    try host.shutdown();
    try std.testing.expect(host.isClosing());
}
test "confirming barrier is controller-bound and released with its view" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &env, .{ .project = project, .id = id, .owner = .foreground });
    defer host.deinit();

    const first = try dispatchJson(host, a, "{\"v\":4,\"id\":1,\"op\":\"attach\",\"write\":true}", 7);
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"epoch\":1") != null);
    const base_rev = host.inbox.snapshot().revision;

    // Pausing claims moves the real revision and the reply already carries it.
    const paused = try dispatchJson(host, a, "{\"v\":4,\"id\":2,\"op\":\"confirming\",\"epoch\":1,\"active\":true}", 7);
    defer a.free(paused);
    try std.testing.expect(std.mem.indexOf(u8, paused, "\"ok\":true") != null);
    try std.testing.expect(host.inbox.snapshot().confirming);
    const paused_rev = try snapshotRevision(a, paused);
    try std.testing.expect(paused_rev != base_rev);
    try std.testing.expectEqual(paused_rev, host.inbox.snapshot().revision);

    // A foreign socket and a stale epoch can neither read nor release it.
    const foreign = try dispatchJson(host, a, "{\"v\":4,\"id\":3,\"op\":\"confirming\",\"epoch\":1,\"active\":false}", 8);
    defer a.free(foreign);
    try std.testing.expect(std.mem.indexOf(u8, foreign, "stale_control") != null);
    const stale = try dispatchJson(host, a, "{\"v\":4,\"id\":4,\"op\":\"confirming\",\"epoch\":9,\"active\":false}", 7);
    defer a.free(stale);
    try std.testing.expect(std.mem.indexOf(u8, stale, "stale_control") != null);
    try std.testing.expect(host.inbox.snapshot().confirming);
    try std.testing.expectEqual(paused_rev, host.inbox.snapshot().revision);

    // A refused takeover leaves the owner's barrier alone.
    const refused = try dispatchJson(host, a, "{\"v\":4,\"id\":5,\"op\":\"attach\",\"write\":true}", 8);
    defer a.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "busy") != null);
    try std.testing.expect(host.inbox.snapshot().confirming);

    // An explicit resume is real: the flag drops and the revision moves again.
    const resumed = try dispatchJson(host, a, "{\"v\":4,\"id\":6,\"op\":\"confirming\",\"epoch\":1,\"active\":false}", 7);
    defer a.free(resumed);
    try std.testing.expect(!host.inbox.snapshot().confirming);
    try std.testing.expect((try snapshotRevision(a, resumed)) != paused_rev);

    // A granted takeover retires the previous owner's barrier.
    const again = try dispatchJson(host, a, "{\"v\":4,\"id\":7,\"op\":\"confirming\",\"epoch\":1,\"active\":true}", 7);
    defer a.free(again);
    try std.testing.expect(host.inbox.snapshot().confirming);
    const takeover = try dispatchJson(host, a, "{\"v\":4,\"id\":8,\"op\":\"attach\",\"write\":true,\"takeover\":true}", 8);
    defer a.free(takeover);
    try std.testing.expect(std.mem.indexOf(u8, takeover, "\"epoch\":2") != null);
    try std.testing.expect(!host.inbox.snapshot().confirming);
    // The old socket's epoch is dead, so it cannot re-open the barrier.
    const old = try dispatchJson(host, a, "{\"v\":4,\"id\":9,\"op\":\"confirming\",\"epoch\":1,\"active\":true}", 7);
    defer a.free(old);
    try std.testing.expect(std.mem.indexOf(u8, old, "stale_control") != null);
    try std.testing.expect(!host.inbox.snapshot().confirming);

    // EOF releases the controlling socket only; a non-owner EOF changes nothing.
    const paused_new = try dispatchJson(host, a, "{\"v\":4,\"id\":10,\"op\":\"confirming\",\"epoch\":2,\"active\":true}", 8);
    defer a.free(paused_new);
    try std.testing.expect(host.inbox.snapshot().confirming);
    host.disconnected(7);
    try std.testing.expect(host.inbox.snapshot().confirming);
    host.disconnected(8);
    try std.testing.expect(!host.inbox.snapshot().confirming);

    // A stale detach does not release; the live epoch does.
    const third = try dispatchJson(host, a, "{\"v\":4,\"id\":11,\"op\":\"attach\",\"write\":true}", 9);
    defer a.free(third);
    try std.testing.expect(std.mem.indexOf(u8, third, "\"epoch\":3") != null);
    const paused_third = try dispatchJson(host, a, "{\"v\":4,\"id\":12,\"op\":\"confirming\",\"epoch\":3,\"active\":true}", 9);
    defer a.free(paused_third);
    const stale_detach = try dispatchJson(host, a, "{\"v\":4,\"id\":13,\"op\":\"detach\",\"epoch\":3}", 7);
    defer a.free(stale_detach);
    try std.testing.expect(host.inbox.snapshot().confirming);
    const detach = try dispatchJson(host, a, "{\"v\":4,\"id\":14,\"op\":\"detach\",\"epoch\":3}", 9);
    defer a.free(detach);
    try std.testing.expect(!host.inbox.snapshot().confirming);

    try host.shutdown();
}
test "history reply is valid JSON with truncated outside the entries array" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &env, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    // Startup canonical rows, exactly as a restored checkpoint publishes them.
    const messages = [_]p.Message{
        .{ .role = .context, .blocks = &.{.{ .text = "machine prefix must not be displayed" }} },
        .{ .role = .user, .blocks = &.{.{ .text = "first question" }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "first answer" }} },
    };
    host.seedHistory(&messages);
    try std.testing.expect(host.history.items.items.len == 2);

    const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":21,\"op\":\"history\",\"limit\":4}", 1);
    defer a.free(frame);
    var parsed = try parseJson(a, frame);
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expect(object.get("ok").?.bool);
    try std.testing.expect(object.get("truncated") != null);
    try std.testing.expectEqual(std.json.Value{ .bool = false }, object.get("truncated").?);
    const entries = object.get("entries").?.array.items;
    var saw_user = false;
    var saw_assistant = false;
    var saw_prefix = false;
    for (entries) |entry| {
        const kind = entry.object.get("t").?.string;
        if (std.mem.eql(u8, kind, "user")) {
            const value = entry.object.get("v").?;
            if (std.mem.eql(u8, value.string, "first question")) saw_user = true;
        }
        if (std.mem.eql(u8, kind, "assistant")) {
            const blocks = entry.object.get("blocks").?.array.items;
            for (blocks) |block| {
                const text = block.object.get("v") orelse continue;
                if (std.mem.eql(u8, text.string, "first answer")) saw_assistant = true;
                if (std.mem.indexOf(u8, text.string, "machine prefix") != null) saw_prefix = true;
            }
        }
    }
    try std.testing.expect(saw_user and saw_assistant and !saw_prefix);
    try std.testing.expect(object.get("base").?.integer > 0);
}
test "bridge display metadata is stored and the approval detail survives reconnect" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    // A truncated canonical array must keep both flags in the stored ring.
    const blocks = try a.alloc(p.Block, protocol.max_blocks + 1);
    defer a.free(blocks);
    for (blocks) |*block| block.* = .{ .text = "x" };
    host.observe(.{ .assistant_committed = blocks }, true, false);
    const stored = host.history.items.items[host.history.items.items.len - 1].json;
    try std.testing.expect(std.mem.indexOf(u8, stored, "\"disp_trunc\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, stored, "\"canon_complete\":false") != null);
    // Stored events are epoch-free: old history replays after takeover.
    try std.testing.expect(std.mem.indexOf(u8, stored, "\"epoch\":0") != null);

    host.setPending(9, "bash", "rm -rf /var/tmp/x", false);
    const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":22,\"op\":\"history\"}", 1);
    defer a.free(frame);
    var parsed = try parseJson(a, frame);
    defer parsed.deinit();
    var saw_permission = false;
    for (parsed.value.object.get("entries").?.array.items) |entry| {
        if (!std.mem.eql(u8, entry.object.get("t").?.string, "permission")) continue;
        try std.testing.expectEqual(@as(i64, 9), entry.object.get("id").?.integer);
        try std.testing.expectEqualStrings("bash", entry.object.get("name").?.string);
        try std.testing.expectEqualStrings("rm -rf /var/tmp/x", entry.object.get("desc").?.string);
        saw_permission = true;
    }
    try std.testing.expect(saw_permission);
    host.clearPending();
}
test "long approval detail survives reconnect whole and stays approvable" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    // 12 KiB of a real destructive command: far past the old 4096 display
    // bound but inside the Bridge's 64 KiB per-event budget.
    const command = try a.alloc(u8, 12 * 1024);
    defer a.free(command);
    @memset(command, 'x');
    @memcpy(command[0.."rm -rf /".len], "rm -rf /");
    @memcpy(command[command.len - 3 ..], "-rf");

    const runtime_host = host.bridge.host();
    try runtime_host.emit_fn(runtime_host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = command } }, &host.cancel);
    host.pump(0);
    try std.testing.expectEqual(@as(?u64, 1), host.pending_permission);
    try std.testing.expect(!host.pending_detail_incomplete);
    try std.testing.expectEqual(command.len, host.pending_desc.?.len);

    // A reconnected viewer sees the whole command and no clipping marker.
    const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":80,\"op\":\"history\"}", 1);
    defer a.free(frame);
    var parsed = try parseJson(a, frame);
    defer parsed.deinit();
    var seen = false;
    for (parsed.value.object.get("entries").?.array.items) |entry| {
        if (!std.mem.eql(u8, entry.object.get("t").?.string, "permission")) continue;
        const desc = entry.object.get("desc").?.string;
        try std.testing.expect(command.len > 4096);
        try std.testing.expectEqualStrings(command, desc);
        try std.testing.expect(entry.object.get("disp_trunc") == null);
        seen = true;
    }
    try std.testing.expect(seen);

    // Offline approval of an untruncated dangerous request still works.
    const attach = try dispatchJson(host, a, "{\"v\":4,\"id\":81,\"op\":\"attach\",\"write\":true}", 1);
    defer a.free(attach);
    const granted = try dispatchJson(host, a, "{\"v\":4,\"id\":82,\"op\":\"approve\",\"epoch\":1,\"permission_id\":1,\"allow\":true}", 1);
    defer a.free(granted);
    try std.testing.expect(std.mem.indexOf(u8, granted, "\"ok\":true") != null);
}
test "a clipped approval detail is never silently allowed" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    // Above the Bridge's single-event text budget: the display copy is a prefix.
    const command = try a.alloc(u8, bridge_mod.item_budget + 1024);
    defer a.free(command);
    @memset(command, 'y');

    const runtime_host = host.bridge.host();
    try runtime_host.emit_fn(runtime_host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = command } }, &host.cancel);
    host.pump(0);
    try std.testing.expectEqual(@as(?u64, 1), host.pending_permission);
    try std.testing.expect(host.pending_detail_incomplete);
    // The name is copied first, so the detail keeps the remaining budget.
    try std.testing.expectEqual(bridge_mod.item_budget - "bash".len, host.pending_desc.?.len);

    // The rebuilt row carries the clipping flag instead of looking complete.
    const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":90,\"op\":\"history\"}", 1);
    defer a.free(frame);
    var parsed = try parseJson(a, frame);
    defer parsed.deinit();
    var seen = false;
    for (parsed.value.object.get("entries").?.array.items) |entry| {
        if (!std.mem.eql(u8, entry.object.get("t").?.string, "permission")) continue;
        try std.testing.expectEqual(bridge_mod.item_budget - "bash".len, entry.object.get("desc").?.string.len);
        try std.testing.expectEqual(std.json.Value{ .bool = true }, entry.object.get("disp_trunc").?);
        seen = true;
    }
    try std.testing.expect(seen);

    const attach = try dispatchJson(host, a, "{\"v\":4,\"id\":91,\"op\":\"attach\",\"write\":true}", 1);
    defer a.free(attach);
    // Allowing what the viewer cannot fully see is refused, not applied.
    const refused = try dispatchJson(host, a, "{\"v\":4,\"id\":92,\"op\":\"approve\",\"epoch\":1,\"permission_id\":1,\"allow\":true}", 1);
    defer a.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "input_too_large") != null);
    // Nothing was answered: a deny for the same id is still a live decision.
    const denied = try dispatchJson(host, a, "{\"v\":4,\"id\":93,\"op\":\"approve\",\"epoch\":1,\"permission_id\":1,\"allow\":false}", 1);
    defer a.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "\"ok\":true") != null);
}
test "submit receipt nonce is bound to kind and exact content" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    // Attach a controller epoch on connection 1.
    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":30,\"op\":\"attach\",\"write\":true}", 1);
        defer a.free(frame);
    }
    const zero = try dispatchJson(host, a, "{\"v\":4,\"id\":35,\"op\":\"submit\",\"epoch\":1,\"req\":0,\"kind\":\"prompt\",\"text\":\"alpha\"}", 1);
    defer a.free(zero);
    var parsed_zero = try parseJson(a, zero);
    defer parsed_zero.deinit();
    try std.testing.expect(!parsed_zero.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("protocol", parsed_zero.value.object.get("err").?.string);
    try std.testing.expectEqual(@as(usize, 0), host.receipt_next);
    try std.testing.expect(host.task == null);

    const first = try dispatchJson(host, a, "{\"v\":4,\"id\":31,\"op\":\"submit\",\"epoch\":1,\"req\":77,\"kind\":\"prompt\",\"text\":\"alpha\"}", 1);
    defer a.free(first);
    // No credentials: the task is rejected but the rejection is recorded.
    try std.testing.expect(std.mem.indexOf(u8, first, "\"ok\":false") != null);

    const replay = try dispatchJson(host, a, "{\"v\":4,\"id\":32,\"op\":\"submit\",\"epoch\":1,\"req\":77,\"kind\":\"prompt\",\"text\":\"alpha\"}", 1);
    defer a.free(replay);
    var parsed_replay = try parseJson(a, replay);
    defer parsed_replay.deinit();
    try std.testing.expect(parsed_replay.value.object.get("ok").?.bool);
    try std.testing.expect(!parsed_replay.value.object.get("accepted").?.bool);
    try std.testing.expect(parsed_replay.value.object.get("duplicate").?.bool);

    // Same nonce, different content/kind: rejected instead of "already accepted".
    const other_text = try dispatchJson(host, a, "{\"v\":4,\"id\":33,\"op\":\"submit\",\"epoch\":1,\"req\":77,\"kind\":\"prompt\",\"text\":\"beta\"}", 1);
    defer a.free(other_text);
    try std.testing.expect(std.mem.indexOf(u8, other_text, "invalid_input") != null);
    const other_kind = try dispatchJson(host, a, "{\"v\":4,\"id\":34,\"op\":\"submit\",\"epoch\":1,\"req\":77,\"kind\":\"compact\",\"text\":\"alpha\"}", 1);
    defer a.free(other_kind);
    try std.testing.expect(std.mem.indexOf(u8, other_kind, "invalid_input") != null);
}
test "history and event replies are clipped by encoded bytes not ring capacity" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    // This fixture isolates per-frame clipping from the live-retention bound.
    host.events.budget = 4 * 1024 * 1024;
    const chunk = try a.alloc(u8, 60 * 1024);
    defer a.free(chunk);
    @memset(chunk, 'a');
    for (0..40) |_| {
        const json = try protocol.encodeEventMeta(a, .{ .user_committed = .{ .id = 1, .text = chunk } }, .{ .epoch = 0, .truncated = false, .canonical_complete = true });
        try host.history.push(host.takeSeq(), json);
        const text_json = try protocol.encodeEventMeta(a, .{ .text = chunk }, .{ .epoch = 0, .truncated = false, .canonical_complete = true });
        try host.events.push(host.takeSeq(), text_json);
    }

    const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":40,\"op\":\"history\",\"limit\":32}", 1);
    defer a.free(frame);
    try std.testing.expect(frame.len <= protocol.max_response);
    var parsed = try parseJson(a, frame);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);

    const events = try dispatchJson(host, a, "{\"v\":4,\"id\":41,\"op\":\"events\",\"since\":0,\"max\":32}", 1);
    defer a.free(events);
    try std.testing.expect(events.len <= protocol.max_response);
    var events_parsed = try parseJson(a, events);
    defer events_parsed.deinit();
    try std.testing.expect(events_parsed.value.object.get("truncated").?.bool);
    try std.testing.expect(events_parsed.value.object.get("next").?.integer > 0);
}
test "direct input is history-only while queued input is rendered exactly once" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    _ = host.noteSubmittedUser("direct prompt");
    host.noteQueuedUser(11, "queued follow-up");

    // The direct prompt is canonical history but was never echoed as an event.
    var direct_in_events = false;
    for (host.events.items.items) |entry| {
        if (std.mem.indexOf(u8, entry.json, "direct prompt") != null) direct_in_events = true;
    }
    try std.testing.expect(!direct_in_events);

    const queued_events = blk: {
        var count: usize = 0;
        for (host.events.items.items) |entry| {
            if (std.mem.indexOf(u8, entry.json, "queued follow-up") != null) count += 1;
        }
        break :blk count;
    };
    try std.testing.expectEqual(@as(usize, 1), queued_events);

    const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":50,\"op\":\"history\",\"limit\":8}", 1);
    defer a.free(frame);
    var parsed = try parseJson(a, frame);
    defer parsed.deinit();
    var direct_rows: usize = 0;
    var queued_rows: usize = 0;
    for (parsed.value.object.get("entries").?.array.items) |entry| {
        const value = entry.object.get("v") orelse continue;
        const text = switch (value) {
            .string => |bytes| bytes,
            else => continue,
        };
        if (std.mem.eql(u8, text, "direct prompt")) direct_rows += 1;
        if (std.mem.eql(u8, text, "queued follow-up")) queued_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), direct_rows);
    try std.testing.expectEqual(@as(usize, 1), queued_rows);
}
test "accepted queue entries are kept and paused when no runtime can start them" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    const attach = try dispatchJson(host, a, "{\"v\":4,\"id\":60,\"op\":\"attach\",\"write\":true}", 1);
    defer a.free(attach);
    const queued = try dispatchJson(host, a, "{\"v\":4,\"id\":61,\"op\":\"enqueue\",\"epoch\":1,\"kind\":\"follow_up\",\"text\":\"next step\"}", 1);
    defer a.free(queued);
    try std.testing.expect(std.mem.indexOf(u8, queued, "\"ok\":true") != null);
    try std.testing.expectEqual(@as(usize, 1), host.inbox.snapshot().follow_up);

    // No configured Runtime: the pump must not drop or duplicate the message.
    host.pump(0);
    try std.testing.expectEqual(@as(usize, 1), host.inbox.snapshot().follow_up);
    try std.testing.expect(host.task == null);

    // An explicit resume while still unavailable also keeps the message.
    const resumed = try dispatchJson(host, a, "{\"v\":4,\"id\":62,\"op\":\"queue_resume\",\"epoch\":1}", 1);
    defer a.free(resumed);
    host.pump(0);
    try std.testing.expectEqual(@as(usize, 1), host.inbox.snapshot().follow_up);
    var rendered: usize = 0;
    for (host.events.items.items) |entry| {
        if (std.mem.indexOf(u8, entry.json, "next step") != null) rendered += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), rendered);
}
test "per-agent status rows snapshot pages retain every row" {
    const a = std.testing.allocator;
    const Agent = @import("../core/subagent_status.zig").AgentView;
    const rows = try a.alloc(Agent, 130);
    defer a.free(rows);
    for (rows, 0..) |*row, i| row.* = .{ .id = @intCast(i + 1), .phase = .running };
    const source: protocol.Snapshot = .{ .session = @splat('a'), .project = "/tmp", .owner = .daemon, .subagents_supported = true, .subagents = .{ .group_id = 7, .revision = 1, .total = rows.len, .running = rows.len, .latest_id = rows.len, .agents = rows } };
    var offset: u64 = 0;
    var seen: usize = 0;
    while (true) {
        var snapshot = source;
        const page = SessionHost.pageSnapshot(&snapshot, offset, 7);
        try std.testing.expectEqual(offset, snapshot.subagents.page_offset.?);
        try std.testing.expect(snapshot.subagents.agents.len <= 64);
        for (snapshot.subagents.agents) |row| {
            seen += 1;
            try std.testing.expectEqual(@as(u64, @intCast(seen)), row.id);
        }
        if (page.next == 0) break;
        offset = page.next;
    }
    try std.testing.expectEqual(rows.len, seen);
    var replacement = source;
    const restarted = SessionHost.pageSnapshot(&replacement, 64, 6);
    try std.testing.expectEqual(@as(u64, 0), replacement.subagents.page_offset.?);
    try std.testing.expectEqual(@as(u64, 64), restarted.next);
}
test "snapshot reply encodes caller-owned queued previews consistently" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    const attach = try dispatchJson(host, a, "{\"v\":4,\"id\":80,\"op\":\"attach\",\"write\":true}", 1);
    defer a.free(attach);
    var attach_parsed = try parseJson(a, attach);
    defer attach_parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), attach_parsed.value.object.get("epoch").?.integer);

    const expected = [_][]const u8{ "第一条 \"引号\" 预览", "第二条 中文 \"quotes\" 预览" };
    const enqueued = [_][]const u8{
        "{\"v\":4,\"id\":81,\"op\":\"enqueue\",\"epoch\":1,\"kind\":\"steering\",\"text\":\"第一条 \\\"引号\\\" 预览\"}",
        "{\"v\":4,\"id\":82,\"op\":\"enqueue\",\"epoch\":1,\"kind\":\"follow_up\",\"text\":\"第二条 中文 \\\"quotes\\\" 预览\"}",
    };
    for (enqueued) |request| {
        const reply = try dispatchJson(host, a, request, 1);
        defer a.free(reply);
        var parsed = try parseJson(a, reply);
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("ok").?.bool);
    }

    var round: usize = 0;
    while (round < 3) : (round += 1) {
        // Stack churn between rounds: sibling replies reuse the frames that held
        // the previous projection. Only caller-owned storage survives this.
        const churn_requests = [_][]const u8{
            "{\"v\":4,\"id\":83,\"op\":\"history\",\"limit\":8}",
            "{\"v\":4,\"id\":84,\"op\":\"events\",\"since\":0,\"max\":8}",
        };
        for (churn_requests) |request| {
            const churn = try dispatchJson(host, a, request, 1);
            var churn_parsed = try parseJson(a, churn);
            churn_parsed.deinit();
            a.free(churn);
        }

        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":90,\"op\":\"snapshot\"}", 1);
        var parsed = try parseJson(a, frame);
        a.free(frame);
        defer parsed.deinit();
        // Missing or mistyped fields fail the test as errors instead of
        // panicking through `.?` on the optional.
        const Probe = struct {
            fn of(object: std.json.ObjectMap, name: []const u8) !std.json.Value {
                return object.get(name) orelse error.TestExpectedField;
            }
            fn integer(object: std.json.ObjectMap, name: []const u8) !i64 {
                return switch (try of(object, name)) {
                    .integer => |value| value,
                    else => error.TestUnexpectedFieldType,
                };
            }
            fn boolean(object: std.json.ObjectMap, name: []const u8) !bool {
                return switch (try of(object, name)) {
                    .bool => |value| value,
                    else => error.TestUnexpectedFieldType,
                };
            }
            fn string(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
                return switch (try of(object, name)) {
                    .string => |value| value,
                    else => error.TestUnexpectedFieldType,
                };
            }
            fn objectOf(value: std.json.Value) !std.json.ObjectMap {
                return switch (value) {
                    .object => |value_object| value_object,
                    else => error.TestUnexpectedFieldType,
                };
            }
            fn arrayOf(value: std.json.Value) ![]std.json.Value {
                return switch (value) {
                    .array => |value_array| value_array.items,
                    else => error.TestUnexpectedFieldType,
                };
            }
        };

        const root = parsed.value.object;
        try std.testing.expectEqual(true, try Probe.boolean(root, "ok"));
        // protocol.encodeSnapshot publishes every probe field inside the
        // `snapshot` object; the reply root only carries `ok`.
        const object = try Probe.objectOf(try Probe.of(root, "snapshot"));
        try std.testing.expectEqual(@as(i64, 1), try Probe.integer(object, "steering"));
        try std.testing.expectEqual(@as(i64, 1), try Probe.integer(object, "follow_up"));
        try std.testing.expectEqual(@as(i64, 2), try Probe.integer(object, "queue_revision"));
        try std.testing.expectEqual(@as(i64, 2), try Probe.integer(object, "newest_id"));
        try std.testing.expectEqual(@as(i64, @intCast(expected[1].len)), try Probe.integer(object, "newest_bytes"));
        try std.testing.expectEqual(false, try Probe.boolean(object, "queue_paused"));

        const previews = try Probe.arrayOf(try Probe.of(object, "previews"));
        try std.testing.expectEqual(expected.len, previews.len);
        const kinds = [_][]const u8{ "steering", "follow_up" };
        for (previews, 0..) |item, i| {
            const entry = try Probe.objectOf(item);
            try std.testing.expectEqual(@as(i64, @intCast(i + 1)), try Probe.integer(entry, "id"));
            try std.testing.expectEqualStrings(kinds[i], try Probe.string(entry, "kind"));
            try std.testing.expectEqualStrings(expected[i], try Probe.string(entry, "text"));
        }
    }
}
test "snapshot receipt query is read-only and reports known accepted rejected unknown" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    const digest = submitDigest(.prompt, "alpha");
    host.recordReceipt(55, .prompt, digest, true, 42);
    host.recordReceipt(66, .prompt, digest, false, 0);

    // Accepted, rejected and unknown receipts are answered without any task.
    const cases = [_]struct { id: u64, known: bool, accepted: bool, task: i64 }{
        .{ .id = 55, .known = true, .accepted = true, .task = 42 },
        .{ .id = 66, .known = true, .accepted = false, .task = 0 },
        .{ .id = 777, .known = false, .accepted = false, .task = 0 },
    };
    for (cases) |case| {
        const request = try std.fmt.allocPrint(a, "{{\"v\":4,\"id\":70,\"op\":\"snapshot\",\"receipt\":{d}}}", .{case.id});
        defer a.free(request);
        const frame = try dispatchJson(host, a, request, 1);
        defer a.free(frame);
        var parsed = try parseJson(a, frame);
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expect(object.get("ok").?.bool);
        try std.testing.expectEqual(case.known, object.get("receipt_known").?.bool);
        try std.testing.expectEqual(case.accepted, object.get("receipt_accepted").?.bool);
        try std.testing.expectEqual(case.task, object.get("receipt_task").?.integer);
        try std.testing.expect(host.task == null);
        try std.testing.expectEqual(@as(usize, 0), host.events.items.items.len);
        try std.testing.expectEqual(@as(usize, 0), host.history.items.items.len);
    }

    // A malformed nonce is rejected; it never starts work either.
    const bad = try dispatchJson(host, a, "{\"v\":4,\"id\":71,\"op\":\"snapshot\",\"receipt\":\"abc\"}", 1);
    defer a.free(bad);
    try std.testing.expect(std.mem.indexOf(u8, bad, "\"ok\":false") != null);
    try std.testing.expect(host.task == null);
}
test "settings reply publishes the configured cleanup budgets" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    // A spawning owner reads these two numbers from the public projection; they
    // must be the configured budgets instead of a fixed 30s fallback.
    {
        var fake = FakeLimitsView{
            .prev_fn = host.connection.current_fn,
            .prev_context = host.connection.context,
            .limits = .{ .cleanup_grace_ms = 4_000, .cleanup_timeout_ms = 12_000 },
        };
        defer {
            host.connection.current_fn = fake.prev_fn;
            host.connection.context = fake.prev_context;
        }
        host.connection.current_fn = FakeLimitsView.current;
        host.connection.context = &fake;
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":30,\"op\":\"settings\"}", 7);
        defer a.free(frame);
        try std.testing.expect(try settingsFieldIs(frame, "cleanup_grace_ms", 4_000));
        try std.testing.expect(try settingsFieldIs(frame, "cleanup_timeout_ms", 12_000));
        // The defaults are not what this projection reports, so the two fields
        // are owner state and not literals in the encoder.
        try std.testing.expect(!try settingsFieldIs(frame, "cleanup_grace_ms", 1_000));
        try std.testing.expect(!try settingsFieldIs(frame, "cleanup_timeout_ms", 5_000));
    }

    // The restored real projection reports its own defaults, so both fields are
    // wired to owner state rather than written as literals in the encoder.
    {
        const defaults: cfg.Limits = .{};
        try std.testing.expectEqual(@as(u32, 1_000), defaults.cleanup_grace_ms);
        try std.testing.expectEqual(@as(u32, 5_000), defaults.cleanup_timeout_ms);
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":31,\"op\":\"settings\"}", 7);
        defer a.free(frame);
        try std.testing.expect(try settingsFieldIs(frame, "cleanup_grace_ms", 1_000));
        try std.testing.expect(try settingsFieldIs(frame, "cleanup_timeout_ms", 5_000));
        // And the fake never leaks into the restored real projection.
        try std.testing.expect(!try settingsFieldIs(frame, "cleanup_grace_ms", 4_000));
        try std.testing.expect(!try settingsFieldIs(frame, "cleanup_timeout_ms", 12_000));
    }
}
test "a re-attach on the same socket invalidates cached settings frames by epoch" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":40,\"op\":\"attach\",\"write\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"epoch\":1") != null);
    }
    // The same owner and socket attach again: this is a real new epoch.
    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":41,\"op\":\"attach\",\"write\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"epoch\":2") != null);
    }

    var sink = SettingSink{};
    // A cached frame from the replaced epoch is refused before any owner
    // callback runs: no mutation and no persistence.
    {
        host.connection.setting_fn = SettingSink.set;
        host.connection.context = &sink;
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":42,\"op\":\"setting\",\"epoch\":1,\"key\":\"low_price_input\",\"value\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "stale_control") != null);
        try std.testing.expectEqual(@as(usize, 0), sink.calls);
    }
    // The current epoch on the same socket is allowed and reaches the owner.
    {
        host.connection.setting_fn = SettingSink.set;
        host.connection.context = &sink;
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":43,\"op\":\"setting\",\"epoch\":2,\"key\":\"low_price_input\",\"value\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":false") == null);
        try std.testing.expectEqual(@as(usize, 1), sink.calls);
        try std.testing.expectEqual(tui.Connection.Setting.low_price_input, sink.last_key.?);
        try std.testing.expect(sink.last_value);
    }
    // A different socket still has no authority, even with the live epoch.
    {
        host.connection.setting_fn = SettingSink.set;
        host.connection.context = &sink;
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":44,\"op\":\"setting\",\"epoch\":2,\"key\":\"low_price_input\",\"value\":false}", 8);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "stale_control") != null);
        try std.testing.expectEqual(@as(usize, 1), sink.calls);
    }
    // A missing epoch never degrades to socket-only authority.
    {
        host.connection.setting_fn = SettingSink.set;
        host.connection.context = &sink;
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":45,\"op\":\"setting\",\"key\":\"low_price_input\",\"value\":false}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":false") != null);
        try std.testing.expectEqual(@as(usize, 1), sink.calls);
    }
}
test "proxy mutations require the live epoch and one exact model id" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    {
        const attached = try dispatchJson(host, a, "{\"v\":4,\"id\":1,\"op\":\"attach\",\"write\":true}", 7);
        defer a.free(attached);
        try std.testing.expect(std.mem.indexOf(u8, attached, "\"epoch\":1") != null);
    }

    var sink = ProxySink{};

    // The current epoch on the controller socket reaches the owner with the
    // complete provider/raw-model id and the explicit enable flag. A successful
    // mutation refreshes the connection, so the sink is reinstalled per call.
    {
        host.connection.proxy_fn = ProxySink.set;
        host.connection.context = &sink;
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":2,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"opencode-go/deepseek-v3\",\"enabled\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
        try std.testing.expectEqual(@as(usize, 1), sink.calls);
        try std.testing.expectEqualStrings("opencode-go/deepseek-v3", sink.recorded());
        try std.testing.expect(sink.last_enabled);
    }
    // Disabling the same entry is a real mutation, not a no-op inference.
    {
        host.connection.proxy_fn = ProxySink.set;
        host.connection.context = &sink;
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":3,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"opencode-go/deepseek-v3\",\"enabled\":false}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
        try std.testing.expectEqual(@as(usize, 2), sink.calls);
        try std.testing.expect(!sink.last_enabled);
    }
    // Every later refusal keeps the owner callback untouched.
    host.connection.proxy_fn = ProxySink.set;
    host.connection.context = &sink;
    // A stale epoch and a foreign socket both fail with stale_control; a
    // missing epoch is a bad request. None of them reaches the callback.
    {
        const stale = try dispatchJson(host, a, "{\"v\":4,\"id\":4,\"op\":\"proxy_model\",\"epoch\":9,\"name\":\"p/m\",\"enabled\":true}", 7);
        defer a.free(stale);
        try std.testing.expect(std.mem.indexOf(u8, stale, "stale_control") != null);
    }
    {
        const foreign = try dispatchJson(host, a, "{\"v\":4,\"id\":5,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\",\"enabled\":true}", 8);
        defer a.free(foreign);
        try std.testing.expect(std.mem.indexOf(u8, foreign, "stale_control") != null);
    }
    {
        const bare = try dispatchJson(host, a, "{\"v\":4,\"id\":6,\"op\":\"proxy_model\",\"name\":\"p/m\",\"enabled\":true}", 7);
        defer a.free(bare);
        try std.testing.expect(std.mem.indexOf(u8, bare, "\"ok\":false") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), sink.calls);
    // Loose parameter shapes are rejected instead of defaulted.
    for ([_][]const u8{
        "{\"v\":4,\"id\":7,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\"}",
        "{\"v\":4,\"id\":8,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\",\"enabled\":\"true\"}",
        "{\"v\":4,\"id\":9,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"\",\"enabled\":true}",
        "{\"v\":4,\"id\":10,\"op\":\"proxy_model\",\"epoch\":1,\"enabled\":true}",
    }) |json| {
        const frame = try dispatchJson(host, a, json, 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":false") != null);
        try std.testing.expectEqual(@as(usize, 2), sink.calls);
    }
    // A busy owner refuses before the callback runs.
    {
        host.reset_failed = error.ResetFailed;
        defer host.reset_failed = null;
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":11,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\",\"enabled\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "busy") != null);
        try std.testing.expectEqual(@as(usize, 2), sink.calls);
    }
    // Without an owner callback the op is unsupported, never silently accepted.
    {
        host.connection.proxy_fn = null;
        defer host.connection.proxy_fn = ProxySink.set;
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":12,\"op\":\"proxy_model\",\"epoch\":1,\"name\":\"p/m\",\"enabled\":true}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "unsupported") != null);
        try std.testing.expectEqual(@as(usize, 2), sink.calls);
    }
}
test "proxy endpoint mutation is strict, epoch-bound and publishes only on success" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();
    {
        const attached = try dispatchJson(host, a, "{\"v\":4,\"id\":1,\"op\":\"attach\",\"write\":true}", 7);
        defer a.free(attached);
        try std.testing.expect(std.mem.indexOf(u8, attached, "\"epoch\":1") != null);
    }

    const session_ctx: *anyopaque = @ptrCast(&host.session);
    var sink = ProxyAddressSink{};

    // A full IPv6 endpoint reaches the owner verbatim; a successful save also
    // republishes the session connection, so the test fake must disappear.
    {
        // Capture the real session connection before the fake view is installed
        // so the fake falls back to the live projection, then hand the same
        // connection back once this scope leaves.
        host.refreshConnection();
        var proxy = ProxyViewSink{
            .view = .{
                .prev_fn = host.connection.current_fn,
                .prev_context = host.connection.context,
                .configured = true,
                .names = &.{},
                .address = "stale.invalid",
                .port = 9,
            },
            .sink = &sink,
        };
        host.connection.current_fn = ProxyViewSink.current;
        host.connection.context = &proxy;
        host.connection.proxy_address_fn = ProxyViewSink.set;
        defer host.refreshConnection();
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":2,\"op\":\"proxy_address\",\"epoch\":1,\"value\":\"[2001:db8::1]:8080\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
        try std.testing.expectEqual(@as(usize, 1), sink.calls);
        try std.testing.expectEqualStrings("[2001:db8::1]:8080", sink.recorded());
        try std.testing.expect(host.connection.context == session_ctx);
    }

    // An empty value is a real clear and still reaches the owner callback.
    {
        host.connection.proxy_address_fn = ProxyAddressSink.set;
        host.connection.context = &sink;
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":3,\"op\":\"proxy_address\",\"epoch\":1,\"value\":\"\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":true") != null);
        try std.testing.expectEqual(@as(usize, 2), sink.calls);
        try std.testing.expectEqualStrings("", sink.recorded());
    }

    // Every malformed or loose shape is rejected before the callback.
    host.connection.proxy_address_fn = ProxyAddressSink.set;
    host.connection.context = &sink;
    for ([_][]const u8{
        "{\"v\":4,\"id\":4,\"op\":\"proxy_address\",\"epoch\":1}",
        "{\"v\":4,\"id\":5,\"op\":\"proxy_address\",\"epoch\":1,\"value\":null}",
        "{\"v\":4,\"id\":6,\"op\":\"proxy_address\",\"epoch\":1,\"value\":8080}",
        "{\"v\":4,\"id\":7,\"op\":\"proxy_address\",\"epoch\":1,\"value\":\"2001:db8::1\"}",
        "{\"v\":4,\"id\":8,\"op\":\"proxy_address\",\"epoch\":1,\"value\":\"host:0\"}",
        "{\"v\":4,\"id\":9,\"op\":\"proxy_address\",\"epoch\":1,\"value\":\"host:70000\"}",
        "{\"v\":4,\"id\":10,\"op\":\"proxy_address\",\"epoch\":1,\"value\":\"user@host:8080\"}",
        "{\"v\":4,\"id\":11,\"op\":\"proxy_address\",\"epoch\":1,\"value\":\"http://host:8080\"}",
    }) |json| {
        const frame = try dispatchJson(host, a, json, 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, frame, "unsupported") == null);
        try std.testing.expectEqual(@as(usize, 2), sink.calls);
    }
    {
        var long_value: [cfg.max_proxy_endpoint_bytes + 1]u8 = undefined;
        @memset(&long_value, 'a');
        const too_long = try std.fmt.allocPrint(a, "{{\"v\":4,\"id\":12,\"op\":\"proxy_address\",\"epoch\":1,\"value\":\"{s}\"}}", .{long_value[0..]});
        defer a.free(too_long);
        const frame = try dispatchJson(host, a, too_long, 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "input_too_large") != null);
        try std.testing.expectEqual(@as(usize, 2), sink.calls);
    }

    // Socket and epoch binding, then the idle guard: none reach the callback.
    {
        const stale = try dispatchJson(host, a, "{\"v\":4,\"id\":13,\"op\":\"proxy_address\",\"epoch\":9,\"value\":\"host:8080\"}", 7);
        defer a.free(stale);
        try std.testing.expect(std.mem.indexOf(u8, stale, "stale_control") != null);
    }
    {
        const foreign = try dispatchJson(host, a, "{\"v\":4,\"id\":14,\"op\":\"proxy_address\",\"epoch\":1,\"value\":\"host:8080\"}", 8);
        defer a.free(foreign);
        try std.testing.expect(std.mem.indexOf(u8, foreign, "stale_control") != null);
    }
    {
        host.reset_failed = error.ResetFailed;
        defer host.reset_failed = null;
        const busy = try dispatchJson(host, a, "{\"v\":4,\"id\":15,\"op\":\"proxy_address\",\"epoch\":1,\"value\":\"host:8080\"}", 7);
        defer a.free(busy);
        try std.testing.expect(std.mem.indexOf(u8, busy, "busy") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), sink.calls);

    // A failed owner save returns an error and must NOT republish the settings
    // projection: the installed view survives exactly as it was.
    {
        host.refreshConnection();
        var proxy = ProxyViewSink{
            .view = .{
                .prev_fn = host.connection.current_fn,
                .prev_context = host.connection.context,
                .configured = true,
                .names = &.{},
                .address = "old.invalid",
                .port = 1,
            },
            .sink = &sink,
        };
        host.connection.current_fn = ProxyViewSink.current;
        host.connection.context = &proxy;
        host.connection.proxy_address_fn = ProxyViewSink.set;
        sink.fail = true;
        defer sink.fail = false;
        defer host.refreshConnection();
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":16,\"op\":\"proxy_address\",\"epoch\":1,\"value\":\"host:8080\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "\"ok\":false") != null);
        try std.testing.expectEqual(@as(usize, 3), sink.calls);
        try std.testing.expect(host.connection.context == @as(*anyopaque, @ptrCast(&proxy)));
    }

    // Without an owner callback the op is unsupported, never silently accepted.
    {
        host.connection.context = session_ctx;
        host.connection.proxy_address_fn = null;
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":17,\"op\":\"proxy_address\",\"epoch\":1,\"value\":\"host:8080\"}", 7);
        defer a.free(frame);
        try std.testing.expect(std.mem.indexOf(u8, frame, "unsupported") != null);
        try std.testing.expectEqual(@as(usize, 3), sink.calls);
    }
}
test "settings reply publishes the proxy allowlist without addresses or secrets" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    const names = [_][]const u8{ "opencode-go/deepseek-v3", "deepseek/deepseek-chat" };
    var fake = FakeProxyView{
        .prev_fn = host.connection.current_fn,
        .prev_context = host.connection.context,
        .configured = true,
        .names = &names,
        .address = "2001:db8::1",
        .port = 8443,
    };
    {
        host.connection.current_fn = FakeProxyView.current;
        host.connection.context = &fake;
        defer {
            host.connection.current_fn = fake.prev_fn;
            host.connection.context = fake.prev_context;
        }
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":20,\"op\":\"settings\"}", 7);
        defer a.free(frame);
        var doc = try parseWholeReply(a, frame);
        defer doc.deinit();
        const root = doc.value.object;
        try std.testing.expectEqual(true, root.get("proxy_configured").?.bool);
        // Only the non-secret host/port pair is published: no scheme, path,
        // credentials or headers, and a full IPv6 address stays verbatim.
        try std.testing.expectEqualStrings("2001:db8::1", root.get("proxy_address").?.string);
        try std.testing.expectEqual(@as(i64, 8443), root.get("proxy_port").?.integer);
        const list = root.get("proxy_models").?.array;
        try std.testing.expectEqual(names.len, list.items.len);
        try std.testing.expectEqualStrings(names[0], list.items[0].string);
        try std.testing.expectEqualStrings(names[1], list.items[1].string);
        try std.testing.expectEqual(false, root.get("proxy_models_truncated").?.bool);
        // A model id is projected verbatim: no endpoint, host or credential.
        for (list.items) |entry| {
            try std.testing.expect(std.mem.indexOf(u8, entry.string, "://") == null);
            try std.testing.expect(std.mem.indexOf(u8, entry.string, "@") == null);
        }
        for ([_][]const u8{ "\"key\"", "api_key", "credential", "sk-" }) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, frame, needle) == null);
        }
    }

    // The catalog bound is reported, not silently truncated.
    var many: [257][]const u8 = undefined;
    for (&many) |*entry| entry.* = "p/m";
    fake.names = &many;
    fake.configured = true;
    {
        host.connection.current_fn = FakeProxyView.current;
        host.connection.context = &fake;
        defer {
            host.connection.current_fn = fake.prev_fn;
            host.connection.context = fake.prev_context;
        }
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":21,\"op\":\"settings\"}", 7);
        defer a.free(frame);
        var doc = try parseWholeReply(a, frame);
        defer doc.deinit();
        const root = doc.value.object;
        try std.testing.expectEqual(@as(usize, max_proxy_models), root.get("proxy_models").?.array.items.len);
        try std.testing.expectEqual(true, root.get("proxy_models_truncated").?.bool);
    }

    // The real projection stays unconfigured with a real empty array.
    {
        const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":22,\"op\":\"settings\"}", 7);
        defer a.free(frame);
        var doc = try parseWholeReply(a, frame);
        defer doc.deinit();
        const root = doc.value.object;
        try std.testing.expectEqual(false, root.get("proxy_configured").?.bool);
        try std.testing.expect(root.get("proxy_address").? == .null);
        try std.testing.expectEqual(@as(i64, 0), root.get("proxy_port").?.integer);
        try std.testing.expectEqual(@as(usize, 0), root.get("proxy_models").?.array.items.len);
    }
}
test "settings reply is one parseable JSON object with complete array elements" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const id = try ids.generate(io);
    const host = try SessionHost.init(a, io, &environ, .{ .project = project, .id = id, .owner = .daemon });
    defer host.deinit();

    const models = [_]cfg.Model{
        .{ .name = "fake-one", .context_tokens = 32_000, .output_tokens = 4_000 },
        .{ .name = "fake-two", .context_tokens = 64_000 },
    };
    const model_providers = [_]tui.ModelProvider{
        .{ .name = "fake-login" },
        .{ .name = "fake-proxy", .allow_custom = true },
    };
    // off | low | high: three levels, so the array needs two separators.
    const levels: activity.EffortSet = .{ .mask = 1 | 4 | 16 };

    var fake = FakeCatalogView{
        .prev_fn = host.connection.current_fn,
        .prev_context = host.connection.context,
        .models = &models,
        .providers = &model_providers,
        .levels = levels,
    };
    defer {
        host.connection.current_fn = fake.prev_fn;
        host.connection.context = fake.prev_context;
    }
    host.connection.current_fn = FakeCatalogView.current;
    host.connection.context = &fake;

    const frame = try dispatchJson(host, a, "{\"v\":4,\"id\":50,\"op\":\"settings\"}", 7);
    defer a.free(frame);

    var doc = try parseWholeReply(a, frame);
    defer doc.deinit();
    const root = doc.value.object;
    try std.testing.expectEqual(true, root.get("ok").?.bool);

    const allowed_json = root.get("allowed_providers").?.array;
    try std.testing.expect(allowed_json.items.len > 1);
    try std.testing.expectEqual(@as(usize, 3), allowed_json.items.len);
    try std.testing.expectEqualStrings("deepseek", allowed_json.items[0].string);
    try std.testing.expectEqualStrings("opencode-go", allowed_json.items[2].string);

    const levels_json = root.get("effort_levels").?.array;
    try std.testing.expectEqual(@as(usize, 3), levels_json.items.len);
    try std.testing.expectEqualStrings("off", levels_json.items[0].string);
    try std.testing.expectEqualStrings("high", levels_json.items[2].string);

    const providers_json = root.get("providers").?.array;
    try std.testing.expectEqual(model_providers.len, providers_json.items.len);
    try std.testing.expectEqualStrings("fake-login", providers_json.items[0].object.get("name").?.string);
    try std.testing.expectEqual(true, providers_json.items[1].object.get("allow_custom").?.bool);

    for ([_][]const u8{ "models", "decision_models", "image_models" }) |name| {
        const list = root.get(name).?.array;
        try std.testing.expectEqual(models.len, list.items.len);
        try std.testing.expectEqualStrings("fake-one", list.items[0].object.get("name").?.string);
        try std.testing.expectEqualStrings("fake-two", list.items[1].object.get("name").?.string);
    }

    // A catalog reply never carries credential bytes or credential-shaped keys.
    for ([_][]const u8{ "\"key\"", "api_key", "credential", "sk-" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, frame, needle) == null);
    }
}
