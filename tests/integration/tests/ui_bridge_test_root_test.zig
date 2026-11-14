test "bridge typed tool views own snapshot strings flags and keys" {
    var env = Env.init();
    defer env.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    var source = [_]u8{ 'o', 'w', 'n' };
    const key: p.ToolDisplayKey = .{ .generation = 9, .index = 41 };
    try send(&bridge, .{ .tool_views = .{ .generation = 9, .phase = .begin } });
    try send(&bridge, .{ .tool_view = .{ .key = key, .name = &source, .ready = true, .fields = .{
        .path = .{ .text = &source },
        .command = .{ .text = &source, .truncated = true },
        .action = .{ .text = &source },
        .topic = .{ .text = &source },
    } } });
    @memset(&source, 'x');
    var begin = bridge.pop().?;
    try t.expectEqual(@as(u64, 9), begin.event.tool_views.generation);
    begin.deinit();
    var item = bridge.pop().?;
    defer item.deinit();
    const view = item.event.tool_view;
    try t.expect(view.ready and view.key.eql(key));
    try t.expectEqualStrings("own", view.name);
    inline for (.{ "path", "command", "action", "topic" }) |field_name|
        try t.expectEqualStrings("own", @field(view.fields, field_name).?.text);
    try t.expect(view.fields.command.?.truncated);
    try t.expect(!view.fields.path.?.truncated);
    try t.expect(!item.display_truncated);
    try t.expectEqual(@as(usize, 15), item.storage.len);
}
test "bridge typed fields retain complete source beyond the old item cap" {
    var env = Env.init();
    defer env.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    const huge = try t.allocator.alloc(u8, b.item_budget + 1);
    defer t.allocator.free(huge);
    @memset(huge, 'a');
    try send(&bridge, .{ .tool_view = .{ .key = .{ .generation = 1, .index = 0 }, .name = "bash", .fields = .{
        .command = .{ .text = huge },
        .topic = .{ .text = "tail" },
    } } });
    var item = bridge.pop().?;
    defer item.deinit();
    try t.expectEqual(huge.len + 8, item.storage.len);
    try t.expect(!item.display_truncated);
    try t.expect(!item.event.tool_view.fields.command.?.truncated);
    try t.expect(!item.event.tool_view.fields.topic.?.truncated);
    try t.expectEqualSlices(u8, huge, item.event.tool_view.fields.command.?.text);
    try t.expectEqualStrings("tail", item.event.tool_view.fields.topic.?.text);
}
test "bridge owns every borrowed payload after source arena is freed" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();

    {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // 所有借用字段都指向同一段 arena 内存，便于统一验证拷贝是否完整。
        const s = try a.dupe(u8, "owned");
        const blocks = try a.alloc(p.Block, 4);
        blocks[0] = .{ .text = s };
        blocks[1] = .{ .reasoning = s };
        blocks[2] = .{ .tool_call = .{ .id = s, .name = s, .arguments = s, .item_id = s } };
        blocks[3] = .{ .tool_result = .{ .call_id = s, .text = s, .truncated = true } };
        try send(&bridge, .{ .assistant_committed = blocks });
        try send(&bridge, .{ .text = s });
        try send(&bridge, .{ .reasoning = s });
        try send(&bridge, .{ .tool_preview = .{ .index = 3, .arguments = s } });
        try send(&bridge, .{ .permission = .{ .id = 1, .tool_name = s, .description = s } });
        try send(&bridge, .{ .tool_started = .{ .id = 1, .name = s, .started_ms = 1234 } });
        try send(&bridge, .{ .tool_result = .{ .id = 1, .name = s, .result = .{ .text = s, .cleanup_failed = true, .duration_ms = 567 } } });
        @memset(s, 'x'); // deterministic proof of no borrowing, as well as free
    }

    var item = bridge.pop().?;
    try t.expect(!item.display_truncated);
    const blocks = item.event.assistant_committed;
    try t.expectEqualStrings("owned", blocks[0].text);
    try t.expectEqualStrings("owned", blocks[1].reasoning);
    try t.expectEqualStrings("owned", blocks[2].tool_call.id);
    try t.expectEqualStrings("owned", blocks[2].tool_call.name);
    try t.expectEqualStrings("owned", blocks[2].tool_call.arguments);
    try t.expectEqualStrings("owned", blocks[2].tool_call.item_id.?);
    try t.expectEqualStrings("owned", blocks[3].tool_result.call_id);
    try t.expectEqualStrings("owned", blocks[3].tool_result.text);
    try t.expect(blocks[3].tool_result.truncated);
    item.deinit();
    item = bridge.pop().?;
    try t.expectEqualStrings("owned", item.event.text);
    item.deinit();
    item = bridge.pop().?;
    try t.expectEqualStrings("owned", item.event.reasoning);
    item.deinit();
    item = bridge.pop().?;
    try t.expectEqualStrings("owned", item.event.tool_preview.arguments);
    item.deinit();
    item = bridge.pop().?;
    try t.expectEqualStrings("owned", item.event.permission.tool_name);
    try t.expectEqualStrings("owned", item.event.permission.description);
    item.deinit();
    item = bridge.pop().?;
    try t.expectEqualStrings("owned", item.event.tool_started.name);
    try t.expectEqual(@as(?u64, 1234), item.event.tool_started.started_ms);
    item.deinit();
    item = bridge.pop().?;
    try t.expectEqualStrings("owned", item.event.tool_result.name);
    try t.expectEqualStrings("owned", item.event.tool_result.result.text);
    try t.expect(item.event.tool_result.result.cleanup_failed);
    try t.expectEqual(@as(?u64, 567), item.event.tool_result.result.duration_ms);
    item.deinit();
}
test "file statistics and complete large result JSON survive owned copying" {
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, t.io, &cancel);
    defer bridge.deinit();
    const big = try t.allocator.alloc(u8, b.item_budget + 100);
    defer t.allocator.free(big);
    @memset(big, 'x');
    try send(&bridge, .{ .tool_result = .{ .id = 9, .name = "read_file", .result = .{ .text = big, .file_stats = .{ .read = 20000, .partial = true } } } });
    try send(&bridge, .{ .context_snapshot = .{ .tokens = 700, .limit = 32768 } });
    var item = bridge.pop().?;
    try t.expect(item.display_truncated);
    try t.expectEqual(@as(usize, b.item_budget), item.event.tool_result.result.text.len);
    try t.expectEqualSlices(u8, big[0..b.item_budget], item.event.tool_result.result.text);
    try t.expectEqual(@as(?u64, 20000), item.event.tool_result.result.file_stats.?.read);
    try t.expect(item.event.tool_result.result.file_stats.?.partial);
    item.deinit();
    item = bridge.pop().?;
    try t.expectEqual(@as(u64, 700), item.event.context_snapshot.tokens);
    item.deinit();
}
test "independent cancellation rejects new emission without losing queued events" {
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, t.io, &cancel);
    defer bridge.deinit();
    try fill(&bridge);
    cancel.cancel();
    try t.expectError(error.Canceled, blockedEmit(&bridge));
    try t.expectEqual(old_queue_capacity + 1, bridge.len);
    drain(&bridge);
    try t.expectEqual(@as(usize, 0), bridge.bytes);
}
test "close rejects further emission and terminal bypasses cancellation and queue" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    try fill(&bridge);
    bridge.close();
    try t.expect(cancel.isRequested());
    try t.expectError(error.Canceled, blockedEmit(&bridge));
    try send(&bridge, .{ .finished = .{ .status = .canceled, .detail = error.Canceled } });
    try t.expectEqual(r.Status.canceled, bridge.takeTerminal().?.status);
    try t.expect(bridge.takeTerminal() == null);
    try t.expectEqual(old_queue_capacity + 1, bridge.len);
}
test "reliable result grows queue beyond the old capacity in FIFO order" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    try fill(&bridge);
    var worker = try Io.concurrent(bridge.io, blockedEmit, .{&bridge});
    defer worker.cancel(bridge.io) catch {};
    try worker.await(bridge.io);
    try t.expectEqual(old_queue_capacity + 2, bridge.len);
    for (0..old_queue_capacity + 1) |_| {
        var item = bridge.pop().?;
        item.deinit();
    }
    var result = bridge.pop().?;
    defer result.deinit();
    try t.expectEqualStrings("reliable", result.event.tool_result.result.text);
}
test "permission accepts early decision, rejects wrong stale and duplicate IDs; reset revokes pending approval" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    try t.expect(!bridge.decide(1, .allow_once));

    try send(&bridge, .{ .permission = .{ .id = 1, .tool_name = "x", .description = "y" } });
    try t.expect(!bridge.decide(2, .allow_once));
    try t.expect(bridge.decide(1, .allow_once));
    try t.expect(!bridge.decide(1, .deny));
    try t.expectEqual(r.Decision.deny, try auth(&bridge, 2));
    try t.expectEqual(r.Decision.allow_once, try auth(&bridge, 1));
    try t.expect(!bridge.decide(1, .allow_once));
    try t.expectEqual(r.Decision.deny, try auth(&bridge, 1));

    // 仍有未释放的队列条目时 reset 必须返回 Busy；先排空并关闭后才能重置。
    try t.expectError(error.Busy, bridge.reset());
    drain(&bridge);
    bridge.close();
    try bridge.reset();
    try t.expect(!cancel.isRequested());
    try t.expect(!bridge.decide(1, .allow_once));
    try t.expectError(error.InvalidPermission, send(&bridge, .{ .permission = .{ .id = 1, .tool_name = "x", .description = "y" } }));
    try send(&bridge, .{ .permission = .{ .id = 2, .tool_name = "x", .description = "y" } });
    try t.expect(!bridge.decide(1, .allow_once));
    try t.expect(bridge.decide(2, .deny));
    try t.expectEqual(r.Decision.deny, try auth(&bridge, 2));
    drain(&bridge);

    try send(&bridge, .{ .permission = .{ .id = 3, .tool_name = "x", .description = "y" } });
    try t.expect(bridge.decide(3, .allow_once));
    drain(&bridge);
    try bridge.reset();
    try t.expectEqual(r.Decision.deny, try auth(&bridge, 3));
    try send(&bridge, .{ .permission = .{ .id = 4, .tool_name = "x", .description = "y" } });
    try t.expect(bridge.decide(4, .deny));
    try t.expectEqual(r.Decision.deny, try auth(&bridge, 4));
}
test "permission installed before enqueue; cancel while awaiting permission clears it" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    try fill(&bridge);

    const Emit = struct {
        fn run(br: *b.Bridge) !void {
            try send(br, .{ .permission = .{ .id = 7, .tool_name = "x", .description = "y" } });
        }
    };
    var emitter = try Io.concurrent(bridge.io, Emit.run, .{&bridge});
    defer emitter.cancel(bridge.io) catch {};
    try emitter.await(bridge.io);
    try t.expectEqual(old_queue_capacity + 2, bridge.len);
    try t.expect(bridge.decide(7, .allow_once));
    try t.expectEqual(r.Decision.allow_once, try auth(&bridge, 7));
    drain(&bridge);

    try send(&bridge, .{ .permission = .{ .id = 8, .tool_name = "x", .description = "y" } });
    var worker = try Io.concurrent(bridge.io, auth, .{ &bridge, @as(u64, 8) });
    defer _ = worker.cancel(bridge.io) catch .deny;
    try waitActive(&bridge);

    cancel.cancel();
    try t.expectError(error.Canceled, worker.await(bridge.io));
    try t.expect(!bridge.decide(8, .allow_once));
    try t.expect(bridge.pending == null and bridge.answer == null);
}
test "complete large payloads preserve execution flags and every canonical block" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    const huge = try t.allocator.alloc(u8, b.item_budget * 2);
    defer t.allocator.free(huge);
    @memset(huge, 'a');

    try send(&bridge, .{ .tool_result = .{ .id = 1, .name = "name", .result = .{ .text = huge, .is_error = true, .truncated = false } } });
    var item = bridge.pop().?;
    try t.expect(item.display_truncated);
    try t.expectEqual(@as(usize, b.item_budget), item.event.tool_result.result.text.len);
    try t.expectEqualSlices(u8, huge[0..b.item_budget], item.event.tool_result.result.text);
    try t.expect(!item.event.tool_result.result.truncated);
    try t.expect(item.event.tool_result.result.is_error);

    // 已弹出但未 deinit 的条目仍计入占用，因此 reset 返回 Busy。
    try t.expectError(error.Busy, bridge.reset()); // popped ownership counts
    item.deinit();

    try send(&bridge, .{ .tool_preview = .{ .index = 0, .arguments = huge } });
    item = bridge.pop().?;
    try t.expect(!item.display_truncated);
    try t.expectEqualSlices(u8, huge, item.event.tool_preview.arguments);
    item.deinit();

    const blocks = try t.allocator.alloc(p.Block, 10000);
    defer t.allocator.free(blocks);
    @memset(blocks, .{ .text = "" });
    blocks[blocks.len - 1] = .{ .text = "retained-tail" };
    try send(&bridge, .{ .assistant_committed = blocks });
    item = bridge.pop().?;
    try t.expect(!item.display_truncated and item.canonical_complete);
    try t.expectEqual(blocks.len, item.event.assistant_committed.len);
    try t.expectEqualStrings("retained-tail", item.event.assistant_committed[blocks.len - 1].text);
    try t.expectEqual(blocks.len * @sizeOf(p.Block) + "retained-tail".len, item.storage.len);
    item.deinit();
    try bridge.reset();
}
test "allocation failure rolls back reservation and permission; terminal needs no allocation" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var buffer: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var bridge = b.Bridge.init(fixed.allocator(), env.backend.io(), &cancel);
    defer bridge.deinit();

    try t.expectError(error.OutOfMemory, send(&bridge, .{ .permission = .{ .id = 1, .tool_name = "tool", .description = "description" } }));
    try t.expectEqual(@as(usize, 0), bridge.bytes);
    try t.expect(bridge.pending == null and bridge.answer == null);
    try t.expect(!bridge.decide(1, .allow_once));
    try t.expectError(error.OutOfMemory, send(&bridge, .{ .state = .calling_model }));
    try t.expectEqual(@as(usize, 0), bridge.len);

    try send(&bridge, .{ .finished = .{ .status = .failed, .detail = error.OutOfMemory } });
    try t.expectEqual(r.Status.failed, bridge.takeTerminal().?.status);
    try t.expectEqual(@as(usize, 0), bridge.len);
}
test "owned popped bytes remain counted while queue grows beyond old data budget" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();

    const text = try t.allocator.alloc(u8, b.item_budget);
    defer t.allocator.free(text);
    @memset(text, 'a');

    const old_data_budget = 2 * 1024 * 1024;
    const count = old_data_budget / b.item_budget + 1;
    for (0..count) |_| try send(&bridge, .{ .text = text });

    var held = bridge.pop().?;
    var worker = try Io.concurrent(bridge.io, blockedEmit, .{&bridge});
    defer worker.cancel(bridge.io) catch {};
    try worker.await(bridge.io);
    const held_bytes = bridge.bytes;
    try t.expectEqual(count * text.len + "result".len + "reliable".len, held_bytes);
    try t.expect(held_bytes > old_data_budget);
    try t.expectError(error.Busy, bridge.reset());
    held.deinit();
    try t.expectEqual(held_bytes - text.len, bridge.bytes);
    drain(&bridge);
    try t.expectEqual(@as(usize, 0), bridge.bytes);
}
test "permission epoch restarts above the old high water and disconnect stays deny" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    bridge.last_id = std.math.maxInt(u64);
    try t.expectError(error.InvalidPermission, send(&bridge, .{ .permission = .{ .id = 0, .tool_name = "x", .description = "y" } }));
    const host = bridge.host();
    try host.rebase_permission_fn.?(host.context);
    try t.expect(bridge.last_id == null);
    try send(&bridge, .{ .permission = .{ .id = 1, .tool_name = "x", .description = "y" } });
    try t.expect(bridge.decide(1, .deny));
    try t.expectEqual(r.Decision.deny, try auth(&bridge, 1));
    drain(&bridge);

    bridge.disconnected = true;
    try t.expectError(error.Canceled, send(&bridge, .{ .permission = .{ .id = 2, .tool_name = "x", .description = "y" } }));
    try t.expectEqual(r.Decision.deny, try auth(&bridge, 2));
}
