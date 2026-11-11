test "unconsumed body is one latest append while views and control events retain order" {
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
    defer for (&owner.displays) |*slot| if (slot.*) |*display| display.deinit();
    for (0..1600) |_| try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "x" }) } }));
    try std.testing.expectEqual(@as(usize, 1), owner.display_count);
    try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .state = .calling_model }) } }));
    try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "after" }) } }));
    try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .view = try owner.view(true) } }));
    try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "view-after" }) } }));
    try std.testing.expect(owner.publish(.{ .generation = 2, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "new-generation" }) } }));
    try std.testing.expectEqual(@as(usize, 6), owner.display_count);
    for (0..6) |index| {
        var display = (try owner.popDisplay()).?;
        defer display.deinit();
        switch (index) {
            0 => try std.testing.expectEqual(@as(usize, 1600), display.value.event.event.text.len),
            1 => try std.testing.expect(display.value.event.event == .state),
            2 => try std.testing.expectEqualStrings("after", display.value.event.event.text),
            3 => try std.testing.expect(display.value == .view),
            4 => try std.testing.expectEqualStrings("view-after", display.value.event.event.text),
            5 => try std.testing.expectEqual(@as(u64, 2), display.generation),
            else => unreachable,
        }
    }
    try std.testing.expectEqual(@as(usize, 0), owner.display_bytes);
    for (0..Communication.display_capacity - 1) |_| try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .state = .calling_model }) } }));
    for (0..2) |_| try std.testing.expect(owner.publish(.{ .generation = 1, .value = .{ .event = try session.ownEvent(a, 1, .{ .text = "tail" }) } }));
    try std.testing.expectEqual(Communication.display_capacity, owner.display_count);
    const last = (owner.display_head + owner.display_count - 1) % Communication.display_capacity;
    try std.testing.expectEqualStrings("tailtail", owner.displays[last].?.value.event.event.text);
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
    defer std.debug.assert(std.c.pthread_mutex_destroy(&owner.mutex) == .SUCCESS);
    owner.hold_configuration = true;
    client.publication_revision += 1;
    try std.testing.expect(!try owner.produce());
    try std.testing.expectEqual(@as(usize, 0), owner.display_count);
    owner.hold_configuration = false;
    client.epoch += 1;
    try std.testing.expect(!try owner.produce());
    try std.testing.expectEqual(@as(usize, 0), owner.display_count);
    try std.testing.expectEqual(@as(u64, 1), owner.generation);
    owner.command_inflight = false;
    try std.testing.expect(try owner.produce());
    var display = (try owner.popDisplay()).?;
    defer display.deinit();
    try std.testing.expectEqual(@as(u64, 2), display.generation);
    try std.testing.expectEqual(client.epoch, display.value.view.projection.snapshot.control_epoch);
}
test "UI ACK admission coalesces adjacent ranges, keeps holes and never sends a control RPC" {
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

    try std.testing.expectError(error.StaleControl, owner.acknowledge(0, 5));
    try std.testing.expectError(error.InvalidInput, owner.acknowledgeRange(3, 9, 4));
    try owner.acknowledgeRange(3, 10, 20);
    try owner.acknowledgeRange(3, 21, 30);
    try owner.acknowledgeRange(3, 40, 50);
    try owner.acknowledgeRange(3, 0, 9);
    owner.lock();
    try std.testing.expectEqual(@as(u64, 3), owner.ack_epoch);
    try std.testing.expectEqual(@as(usize, 2), owner.ack_ranges.len);
    try std.testing.expectEqual(AckRanges.Range{ .first = 0, .last = 30 }, owner.ack_ranges.items[0]);
    try std.testing.expectEqual(AckRanges.Range{ .first = 40, .last = 50 }, owner.ack_ranges.items[1]);
    owner.unlock();
    // The client has no live epoch in this fixture, so the admitted ranges are
    // dropped as stale instead of being recorded against a foreign view.
    owner.forwardAck();
    owner.lock();
    try std.testing.expectEqual(@as(usize, 0), owner.ack_ranges.len);
    try std.testing.expectEqual(@as(usize, 0), owner.ack_accepted);
    owner.unlock();
    owner.stop.cancel();
    try std.testing.expectError(error.Canceled, owner.acknowledgeRange(3, 60, 70));
}
