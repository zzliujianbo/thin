test "unconsumed body and views retain every ordered event beyond former queue capacity" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    const client = try Client.init(a, io, null, .foreground, path[0..n], path[0..n]);
    defer client.deinit();
    var owner: Communication = .{ .client = client, .a = a, .io = io, .wake = try Wakeup.init(), .ready = try Wakeup.init(), .identity = Communication.Identity.of(client), .revision = 0, .stream_revision = 0 };
    defer owner.wake.deinit();
    defer owner.ready.deinit();
    defer std.debug.assert(std.c.pthread_mutex_destroy(&owner.mutex) == .SUCCESS);
    defer {
        for (owner.displays.items[owner.display_head..]) |*display| display.deinit();
        owner.displays.deinit(a);
    }
    for (0..1600) |_| try owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "x" }) } });
    try std.testing.expectEqual(@as(usize, 1), owner.displays.items.len);
    // A batch has spare geometric capacity, not an exact-size realloc per delta.
    const merged = owner.displays.items[0].value.event;
    try std.testing.expect(merged.storage.len > merged.event.text.len);
    try std.testing.expect(merged.storage.len <= session.max_item_bytes);
    try owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .state = .calling_model }) } });
    try owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "after" }) } });
    try owner.publish(.{ .generation = 1, .value = .{ .view = try owner.view(true) } });
    try owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "view-after" }) } });
    try owner.publish(.{ .generation = 2, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "new-generation" }) } });
    try std.testing.expectEqual(@as(usize, 6), owner.displays.items.len);
    for (0..6) |index| {
        var display = (try owner.popDisplay()).?;
        defer display.deinit();
        try std.testing.expectEqual(@as(u64, if (index == 5) 2 else 1), display.generation);
        switch (index) {
            0 => {
                const body = display.value.event.event.text;
                try std.testing.expectEqual(@as(usize, 1600), body.len);
                for (body) |byte| try std.testing.expectEqual(@as(u8, 'x'), byte);
            },
            1 => try std.testing.expectEqual(.calling_model, display.value.event.event.state),
            2 => try std.testing.expectEqualStrings("after", display.value.event.event.text),
            3 => try std.testing.expect(display.value == .view),
            4 => try std.testing.expectEqualStrings("view-after", display.value.event.event.text),
            5 => try std.testing.expectEqualStrings("new-generation", display.value.event.event.text),
            else => unreachable,
        }
    }
    try std.testing.expectEqual(@as(usize, 0), owner.displays.items.len);
    try std.testing.expect((try owner.popDisplay()) == null);

    // Noncoalescible canonical rows independently cross the old queue capacity.
    // Distinct ids and payloads prove that no row was dropped or reordered.
    for (0..1600) |index| {
        var text: [32]u8 = undefined;
        const body = try std.fmt.bufPrint(&text, "row-{d}", .{index});
        var item = try session.ownEvent(a, 1, .{ .user_committed = .{ .id = @intCast(index + 1), .text = body } });
        errdefer item.deinit();
        try owner.publish(.{ .generation = 2, .value = .{ .event = item } });
    }
    try std.testing.expectEqual(@as(usize, 1600), owner.displays.items.len);
    for (0..1600) |index| {
        var display = (try owner.popDisplay()).?;
        defer display.deinit();
        try std.testing.expectEqual(@as(u64, 2), display.generation);
        const row = display.value.event.event.user_committed;
        try std.testing.expectEqual(@as(u64, @intCast(index + 1)), row.id);
        var text: [32]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&text, "row-{d}", .{index}), row.text);
    }
    try std.testing.expectEqual(@as(usize, 0), owner.displays.items.len);
    try std.testing.expect((try owner.popDisplay()) == null);

    // Crossing the batch boundary preserves the next whole source item, and
    // an individually oversized source remains complete instead of clipped.
    const near_batch = try a.alloc(u8, session.max_item_bytes - 1);
    defer a.free(near_batch);
    @memset(near_batch, 'b');
    const oversized = try a.alloc(u8, session.max_item_bytes + 17);
    defer a.free(oversized);
    @memset(oversized, 'q');
    oversized[session.max_item_bytes] = 'Z';
    const sources = [_][]const u8{ near_batch, "cd", oversized, "tail" };
    for (sources) |body| {
        var item = try session.ownEvent(a, 1, .{ .text = body });
        errdefer item.deinit();
        try owner.publish(.{ .generation = 2, .value = .{ .event = item } });
    }
    try std.testing.expectEqual(@as(usize, 4), owner.displays.items.len);
    for (sources) |body| {
        var display = (try owner.popDisplay()).?;
        defer display.deinit();
        try std.testing.expectEqual(@as(u64, 2), display.generation);
        try std.testing.expect(!display.value.event.display_truncated);
        try std.testing.expect(display.value.event.canonical_complete);
        try std.testing.expectEqualStrings(body, display.value.event.event.text);
    }
    try std.testing.expectEqual(@as(usize, 0), owner.displays.items.len);
    try std.testing.expect((try owner.popDisplay()) == null);
}
test "display FIFO amortizes consumed prefixes and preserves append after pop ownership" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    const client = try Client.init(a, io, null, .foreground, path[0..n], path[0..n]);
    defer client.deinit();
    var owner: Communication = .{ .client = client, .a = a, .io = io, .wake = try Wakeup.init(), .ready = try Wakeup.init(), .identity = Communication.Identity.of(client), .revision = 0, .stream_revision = 0 };
    defer owner.wake.deinit();
    defer owner.ready.deinit();
    defer std.debug.assert(std.c.pthread_mutex_destroy(&owner.mutex) == .SUCCESS);
    defer {
        for (owner.displays.items[owner.display_head..]) |*display| display.deinit();
        owner.displays.deinit(a);
    }
    const Row = struct {
        fn publish(owner_: *Communication, id: usize) !void {
            var text: [32]u8 = undefined;
            var item = try session.ownEvent(owner_.a, 1, .{ .user_committed = .{ .id = @intCast(id), .text = try std.fmt.bufPrint(&text, "row-{d}", .{id}) } });
            errdefer item.deinit();
            try owner_.publish(.{ .generation = 1, .value = .{ .event = item } });
        }
        fn pop(owner_: *Communication, id: usize) !void {
            var display = (try owner_.popDisplay()).?;
            defer display.deinit();
            const row = display.value.event.event.user_committed;
            try std.testing.expectEqual(@as(u64, @intCast(id)), row.id);
            var text: [32]u8 = undefined;
            try std.testing.expectEqualStrings(try std.fmt.bufPrint(&text, "row-{d}", .{id}), row.text);
        }
    };
    for (0..1000) |id| try Row.publish(&owner, id);
    for (0..300) |id| try Row.pop(&owner, id);
    try std.testing.expectEqual(@as(usize, 300), owner.display_head);
    try std.testing.expectEqual(@as(usize, 1000), owner.displays.items.len);
    for (1000..1300) |id| try Row.publish(&owner, id);
    try std.testing.expectEqual(@as(usize, 1000), owner.displays.items.len - owner.display_head);
    for (300..1280) |id| try Row.pop(&owner, id);
    try std.testing.expectEqual(@as(usize, 20), owner.displays.items.len - owner.display_head);
    try std.testing.expect(owner.buffered());
    // Cleanup owns only the unpopped suffix; consumed copies must not be freed.
}
test "display FIFO publication OOM retains the caller item" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var owner: Communication = .{ .client = undefined, .a = a, .io = io, .wake = try Wakeup.init(), .ready = try Wakeup.init(), .identity = undefined, .revision = 0, .stream_revision = 0 };
    defer owner.wake.deinit();
    defer owner.ready.deinit();
    defer owner.displays.deinit(a);
    defer std.debug.assert(std.c.pthread_mutex_destroy(&owner.mutex) == .SUCCESS);
    var item = try session.ownEvent(a, 1, .{ .text = "still owned" });
    defer item.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    owner.a = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, owner.publish(.{ .generation = 1, .value = .{ .event = item } }));
    owner.a = a;
    try std.testing.expectEqualStrings("still owned", item.event.text);
    try std.testing.expectEqual(@as(usize, 0), owner.displays.items.len);
    try std.testing.expectEqual(@as(usize, 0), owner.display_head);
    try std.testing.expect(!owner.buffered());
}
test "inflight session switch cannot publish a new identity before completion" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    const client = try Client.init(a, io, null, .foreground, path[0..n], path[0..n]);
    defer client.deinit();
    var owner: Communication = .{ .client = client, .a = a, .io = io, .wake = try Wakeup.init(), .ready = try Wakeup.init(), .identity = Communication.Identity.of(client), .revision = client.publication_revision, .stream_revision = client.stream_publication_revision, .command_inflight = true };
    defer owner.wake.deinit();
    defer owner.ready.deinit();
    defer owner.displays.deinit(a);
    defer std.debug.assert(std.c.pthread_mutex_destroy(&owner.mutex) == .SUCCESS);
    owner.hold_configuration = true;
    client.publication_revision += 1;
    try std.testing.expect(!try owner.produce());
    try std.testing.expectEqual(@as(usize, 0), owner.displays.items.len);
    owner.hold_configuration = false;
    client.epoch += 1;
    try std.testing.expect(!try owner.produce());
    try std.testing.expectEqual(@as(usize, 0), owner.displays.items.len);
    try std.testing.expectEqual(@as(u64, 1), owner.generation);
    owner.command_inflight = false;
    try std.testing.expect(try owner.produce());
    var display = (try owner.popDisplay()).?;
    defer display.deinit();
    try std.testing.expectEqual(@as(u64, 2), display.generation);
    try std.testing.expectEqual(client.epoch, display.value.view.projection.snapshot.control_epoch);
}
test "UI ACK admission coalesces adjacent ranges keeps holes and never sends a control RPC" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    const client = try Client.init(a, io, null, .foreground, path[0..n], path[0..n]);
    defer client.deinit();
    var owner: Communication = .{ .client = client, .a = a, .io = io, .wake = try Wakeup.init(), .ready = try Wakeup.init(), .identity = Communication.Identity.of(client), .revision = 0, .stream_revision = 0 };
    defer owner.wake.deinit();
    defer owner.ready.deinit();
    defer owner.ack_ranges.deinit(a);
    defer std.debug.assert(std.c.pthread_mutex_destroy(&owner.mutex) == .SUCCESS);
    try std.testing.expectError(error.StaleControl, owner.acknowledge(0, 5));
    try std.testing.expectError(error.InvalidInput, owner.acknowledgeRange(3, 9, 4));
    try owner.acknowledgeRange(3, 10, 20);
    try owner.acknowledgeRange(3, 21, 30);
    try owner.acknowledgeRange(3, 40, 50);
    try owner.acknowledgeRange(3, 0, 9);
    try std.testing.expectEqual(@as(u64, 3), owner.ack_epoch);
    try std.testing.expectEqualSlices(AckRanges.Range, &.{ .{ .first = 0, .last = 30 }, .{ .first = 40, .last = 50 } }, owner.ack_ranges.items.items);
    owner.forwardAck();
    try std.testing.expectEqual(@as(usize, 0), owner.ack_ranges.count());
    try std.testing.expectEqual(@as(usize, 0), owner.ack_accepted);
    owner.stop.cancel();
    try std.testing.expectError(error.Canceled, owner.acknowledgeRange(3, 60, 70));
}
