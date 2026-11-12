test "steering inbox priority restore reservation tombstone and pause" {
    const a = std.testing.allocator;
    var box: Inbox = .{};
    defer box.deinit();
    _ = try box.enqueue(a, .follow_up, "later");
    const id = try box.enqueue(a, .steering, "now");
    box.beginRun();
    const lease = box.claimSteering().?;
    try std.testing.expectEqual(id, lease.id);
    try std.testing.expect(box.withdraw(id) == null);
    box.restore(lease);
    const again = box.claimSteering().?;
    box.pauseClaims(true);
    const snap = box.snapshot();
    var cancel: Cancellation = .{};
    try std.testing.expect(!box.cancelClear(snap.revision - 1, &cancel));
    try std.testing.expect(box.cancelClear(snap.revision, &cancel));
    try std.testing.expectEqualStrings("now", again.text);
    box.restore(again);
    box.finishRun(true);
    try std.testing.expect(box.claimNext() == null);
    try std.testing.expectEqual(@as(usize, 0), box.snapshot().steering);
}
test "steering entry release reaches owning allocator already wiped" {
    const Observer = struct {
        releases: usize = 0,
        clean: bool = true,
        fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
            return false;
        }
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
        fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.releases += 1;
            for (bytes) |byte| if (byte != 0) {
                self.clean = false;
            };
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    var observer: Observer = .{};
    const a: Allocator = .{ .ptr = &observer, .vtable = &.{ .alloc = Observer.alloc, .resize = Observer.resize, .remap = Observer.remap, .free = Observer.free } };
    var box: Inbox = .{};
    defer box.deinit();
    const id = try box.enqueue(a, .steering, "private draft");
    var entry = box.withdraw(id).?;
    entry.deinit();
    _ = try box.enqueue(a, .follow_up, "private followup");
    box.pauseClaims(true);
    var cancel: Cancellation = .{};
    try std.testing.expect(box.cancelClear(box.snapshot().revision, &cancel));
    try std.testing.expectEqual(@as(usize, 2), observer.releases);
    try std.testing.expect(observer.clean);
}
test "steering inbox slots remain reserved and snapshot owns previews" {
    const a = std.testing.allocator;
    var box: Inbox = .{};
    defer box.deinit();
    const id = try box.enqueue(a, .steering, "hello");
    const snap = box.snapshot();
    box.beginRun();
    const lease = box.claimSteering().?;
    for (0..15) |_| _ = try box.enqueue(a, .follow_up, "pending");
    _ = try box.enqueue(a, .follow_up, "overflow");
    try std.testing.expectEqual(@as(usize, 16), box.snapshot().follow_up);
    box.restore(lease);
    var entry = box.withdraw(id).?;
    entry.deinit();
    try std.testing.expectEqualStrings("hello", snap.previews[0].text());
}
test "inbox grows beyond former count and byte limits with lease ordering" {
    const a = std.testing.allocator;
    var box: Inbox = .{};
    defer box.deinit();
    const text = try a.alloc(u8, 70000);
    defer a.free(text);
    @memset(text, 'x');
    var ids: [40]u64 = undefined;
    for (&ids) |*id| id.* = try box.enqueue(a, .steering, text);
    try std.testing.expectEqual(@as(usize, 40), box.snapshot().steering);
    box.beginRun();
    const first = box.claimSteering().?;
    try std.testing.expectEqual(ids[0], first.id);
    box.restore(first);
    for (ids) |id| {
        const lease = box.claimSteering().?;
        try std.testing.expectEqual(id, lease.id);
        try std.testing.expectEqualStrings(text, lease.text);
        var entry = box.commit(lease).?;
        entry.deinit();
    }
    try std.testing.expect(box.sealTask());
}
test "run-gated delivery linearizes with sealing and leaves UI enqueue unchanged" {
    const a = std.testing.allocator;
    var box: Inbox = .{};
    defer box.deinit();
    // Epoch 0: a message may still be parked before the child run exists.
    const pre = try box.enqueueForRun(a, .steering, "before spawn");
    box.beginRun();
    const early = box.claimSteering().?;
    try std.testing.expectEqual(pre, early.id);
    var consumed_early = box.commit(early).?;
    consumed_early.deinit();

    // An open run accepts the message, and that pending owner is exactly what
    // makes the seal fail.
    _ = try box.enqueueForRun(a, .steering, "runtime message");
    try std.testing.expect(!box.sealTask());
    const pending = box.claimSteering().?;
    var consumed = box.commit(pending).?;
    consumed.deinit();
    try std.testing.expect(box.sealTask());
    // The seal won the race: a later run-gated delivery is refused instead of
    // being queued for a run that already ended.
    try std.testing.expectError(error.RunSealed, box.enqueueForRun(a, .steering, "after seal"));
    // Original UI semantics are unchanged: a sealed run may still queue the
    // next turn, and that queued entry does not reopen the run gate.
    const next = try box.enqueue(a, .steering, "next turn");
    try std.testing.expect(box.claimSteering() == null);
    try std.testing.expectError(error.RunSealed, box.enqueueForRun(a, .steering, "during seal"));
    box.finishRun(true);
    try std.testing.expectError(error.RunSealed, box.enqueueForRun(a, .steering, "after finish"));
    // claimSteering requires an active run; claimNext deliberately still lets an
    // idle box prefer the queued steering entry. Restore that entry before the
    // final assertion so a stale lease cannot mask it in deinit.
    try std.testing.expect(box.claimSteering() == null);
    const idle = box.claimNext().?;
    box.restore(idle);
    try std.testing.expectEqual(next, idle.id);
    box.beginRun();
    const resumed = box.claimSteering().?;
    try std.testing.expectEqual(next, resumed.id);
    box.restore(resumed);
}
