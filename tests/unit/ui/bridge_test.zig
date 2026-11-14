test "subagent tool progress is complete and owned independently of producer" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(t.allocator, t.io, &cancel);
    defer bridge.deinit();
    const host_ = bridge.host();
    {
        const source = try t.allocator.alloc(u8, 3000);
        defer t.allocator.free(source);
        @memset(source, 'a');
        @memcpy(source[2046..2049], "字");
        try host_.emit_fn(host_.context, .{ .tool_view = .{
            .key = .{ .generation = 42, .index = 7 },
            .name = "subagent",
            .fields = .{ .id = .{ .text = "job-9" } },
            .subagent_progress = source,
        } }, &cancel);
        @memset(source, 'z');
    }
    var item = bridge.pop().?;
    defer item.deinit();
    const view = item.event.tool_view;
    try t.expectEqual(@as(u64, 42), view.key.generation);
    try t.expectEqual(@as(usize, 7), view.key.index);
    try t.expectEqualStrings("job-9", view.fields.id.?.text);
    const text = view.subagent_progress.?;
    try t.expectEqual(@as(usize, 3000), text.len);
    try t.expect(!item.display_truncated and std.unicode.utf8ValidateSlice(text));
    try t.expectEqualStrings("字", text[2046..2049]);
    try t.expectEqual(@as(u8, 'a'), text[0]);
    try t.expect(@intFromPtr(text.ptr) >= @intFromPtr(item.storage.ptr));
    try t.expect(@intFromPtr(text.ptr) + text.len <= @intFromPtr(item.storage.ptr) + item.storage.len);
}
test "user committed copy owns the entire bounded text including the last byte" {
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var original: [item_budget]u8 = @splat('x');
    original[item_budget - 1] = 'Z';
    const host_ = bridge.host();
    try host_.emit_fn(host_.context, .{ .user_committed = .{ .id = 7, .text = &original } }, &cancel);
    @memset(&original, 'q');
    var item = bridge.pop().?;
    defer item.deinit();
    try std.testing.expectEqual(@as(usize, item_budget), item.event.user_committed.text.len);
    try std.testing.expectEqual(@as(u8, 'x'), item.event.user_committed.text[0]);
    try std.testing.expectEqual(@as(u8, 'Z'), item.event.user_committed.text[item_budget - 1]);
    try std.testing.expect(!item.display_truncated);
}
test "steering interrupts matching pending permission outside bridge lock without denying" {
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var inbox: r.Inbox = .{};
    defer inbox.deinit();
    inbox.beginRun();
    _ = try inbox.enqueue(std.testing.allocator, .steering, "new instruction");
    const host_ = bridge.host();
    try host_.emit_fn(host_.context, .{ .permission = .{ .id = 8, .tool_name = "bash", .description = "not started" } }, &cancel);
    try std.testing.expectError(error.Steered, host_.authorize_fn(host_.context, .{
        .id = 8,
        .tool_name = "bash",
        .description = "not started",
        .interrupt = &inbox,
    }, &cancel));
    try std.testing.expect(bridge.pending == null and bridge.answer == null);
    try std.testing.expect(!cancel.isRequested());
    try std.testing.expectEqual(@as(usize, 1), inbox.snapshot().steering);
}
test "tool view copy owns all six snapshot fields after producer storage is freed" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(t.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    const host_ = bridge.host();

    const expected = [_][]const u8{ "path.txt", "run.sh", "open", "topic-x", "delegate summary", "job-7" };
    var borrowed: [expected.len][]u8 = undefined;
    {
        // Producer-side arena: released and overwritten before the consumer pops.
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        for (expected, 0..) |value, i| borrowed[i] = try arena.allocator().dupe(u8, value);
        try host_.emit_fn(host_.context, .{ .tool_view = .{
            .key = .{ .generation = 5, .index = 2 },
            .name = "background",
            .fields = .{
                .path = .{ .text = borrowed[0] },
                .command = .{ .text = borrowed[1], .truncated = true },
                .action = .{ .text = borrowed[2] },
                .topic = .{ .text = borrowed[3] },
                .task = .{ .text = borrowed[4] },
                .id = .{ .text = borrowed[5], .truncated = true },
            },
            .ready = true,
        } }, &cancel);
        for (borrowed) |slice| @memset(slice, 'x');
    }

    var item = bridge.pop().?;
    defer item.deinit();
    const view = item.event.tool_view;
    try t.expect(!item.display_truncated);
    try t.expectEqualStrings("background", view.name);
    inline for (.{ "path", "command", "action", "topic", "task", "id" }, 0..) |name, i| {
        const text = @field(view.fields, name).?.text;
        try t.expectEqualStrings(expected[i], text);
        // Ownership, not only equal bytes: every non-empty text lives in storage.
        const lo = @intFromPtr(item.storage.ptr);
        try t.expect(@intFromPtr(text.ptr) >= lo);
        try t.expect(@intFromPtr(text.ptr) + text.len <= lo + item.storage.len);
    }
    // Producer-side truncation flags survive; no clipping happened here.
    try t.expect(view.fields.command.?.truncated);
    try t.expect(view.fields.id.?.truncated);
    try t.expect(!view.fields.task.?.truncated);
}
test "task snapshot retains full UTF8 content beyond former item cap" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(t.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    const host_ = bridge.host();

    const huge = try t.allocator.alloc(u8, item_budget + 8);
    defer t.allocator.free(huge);
    var i: usize = 0;
    while (i + 3 <= huge.len) : (i += 3) @memcpy(huge[i..][0..3], "\xe5\xad\x97");
    try host_.emit_fn(host_.context, .{ .tool_view = .{
        .key = .{ .generation = 1, .index = 0 },
        .name = "",
        .fields = .{ .task = .{ .text = huge } },
    } }, &cancel);

    var item = bridge.pop().?;
    defer item.deinit();
    const task = item.event.tool_view.fields.task.?;
    try t.expectEqual(huge.len, task.text.len);
    try t.expectEqualSlices(u8, huge, task.text);
    try t.expect(!task.truncated and !item.display_truncated);
    try t.expect(std.unicode.utf8ValidateSlice(task.text));
}
test "multibyte text body above the item cap streams as ordered untruncated slices" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(t.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    const host_ = bridge.host();
    const body = try multibyteBody(t.allocator);
    defer t.allocator.free(body);

    try host_.emit_fn(host_.context, .{ .text = body }, &cancel);
    // 201 KiB 仍在共享的 256 KiB 预算内，因此一次 emit 就能入队全部切片。
    try t.expectEqual(@as(usize, 4), progress(&bridge).len);
    try t.expectEqual(@as(usize, body.len), progress(&bridge).bytes);

    const drained = try drainBody(&bridge, body, .text);
    try t.expectEqual(@as(usize, 4), drained.parts);
    try t.expectEqual(body.len, drained.bytes);
    try t.expectEqual(@as(usize, 0), progress(&bridge).bytes);
}
test "multibyte reasoning body streams as ordered untruncated slices" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(t.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    const host_ = bridge.host();
    const body = try multibyteBody(t.allocator);
    defer t.allocator.free(body);

    try host_.emit_fn(host_.context, .{ .reasoning = body }, &cancel);
    const drained = try drainBody(&bridge, body, .reasoning);
    try t.expectEqual(@as(usize, 4), drained.parts);
    try t.expectEqual(body.len, drained.bytes);
}
test "empty and exact-bound bodies stay one event while one byte more splits" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(t.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    const host_ = bridge.host();

    // 空正文行为不变：仍然恰好一个空事件，零字节存储，没有截断标记。
    try host_.emit_fn(host_.context, .{ .text = "" }, &cancel);
    try t.expectEqual(@as(usize, 1), progress(&bridge).len);
    {
        var empty = bridge.pop().?;
        defer empty.deinit();
        try t.expect(empty.event == .text);
        try t.expectEqual(@as(usize, 0), empty.event.text.len);
        try t.expectEqual(@as(usize, 0), empty.storage.len);
        try t.expect(!empty.display_truncated and empty.canonical_complete);
    }
    try t.expectEqual(@as(usize, 0), progress(&bridge).bytes);

    // 正好 item_budget 是一条完整事件，不应多切一段。
    const exact = try t.allocator.alloc(u8, item_budget);
    defer t.allocator.free(exact);
    @memset(exact, 'e');
    try host_.emit_fn(host_.context, .{ .text = exact }, &cancel);
    try t.expectEqual(@as(usize, 1), progress(&bridge).len);
    {
        var one = bridge.pop().?;
        defer one.deinit();
        try t.expect(one.event == .text);
        try t.expectEqual(item_budget, one.event.text.len);
        try t.expect(std.mem.eql(u8, one.event.text, exact));
        try t.expect(!one.display_truncated);
    }

    // 多一个字节就切成两段，而不是产出一个被截断的事件。
    const over = try t.allocator.alloc(u8, item_budget + 1);
    defer t.allocator.free(over);
    @memset(over, 'o');
    try host_.emit_fn(host_.context, .{ .text = over }, &cancel);
    const drained = try drainBody(&bridge, over, .text);
    try t.expectEqual(@as(usize, 2), drained.parts);
    try t.expectEqual(over.len, drained.bytes);
}
test "body larger than former byte budget retains every chunk" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    // 与既有 bridge 测试相同的做法：专用线程化后端跑生产者，主线程当消费者。
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var bridge = Bridge.init(t.allocator, backend.io(), &cancel);
    defer bridge.deinit();

    // 1 MiB 正文是整桥预算的 4 倍：只有逐段预留、逐段被消费者回收才可能完成。
    const body = try t.allocator.alloc(u8, 1024 * 1024 + 123);
    defer t.allocator.free(body);
    for (body, 0..) |*byte, i| byte.* = @truncate(i % 251);
    const got = try t.allocator.alloc(u8, body.len);
    defer t.allocator.free(got);

    var producer = BodyProducer{ .host_ = bridge.host(), .cancel = &cancel, .body = body };
    var worker = try Io.concurrent(bridge.io, BodyProducer.run, .{&producer});
    defer worker.cancel(bridge.io) catch {};

    var seen: usize = 0;
    var parts: usize = 0;
    var oversize = false;
    var clipped = false;
    while (seen < got.len) {
        if (bridge.pop()) |value| {
            var item = value;
            defer item.deinit();
            if (item.event != .text) {
                oversize = true;
                continue;
            }
            const part = item.event.text;
            if (part.len > got.len - seen) {
                oversize = true;
                continue;
            }
            @memcpy(got[seen..][0..part.len], part);
            seen += part.len;
            parts += 1;
            if (part.len > item_budget or item.display_truncated) clipped = true;
            continue;
        }
        if (producer.done.load(.acquire)) break;
        try Io.sleep(bridge.io, .fromMilliseconds(1), .awake);
    }
    try worker.await(bridge.io);

    try t.expect(producer.err == null);
    try t.expect(!oversize and !clipped);
    try t.expectEqual(body.len, seen);
    try t.expect(std.mem.eql(u8, got, body));
    try t.expect(parts >= body.len / item_budget);
    // 全部切片都已归还预算，1 MiB 从未被整体预留。
    try t.expectEqual(@as(usize, 0), progress(&bridge).bytes);
    try t.expectEqual(@as(usize, 0), progress(&bridge).outstanding);
}
test "cancel after delivered split chunks keeps only the truthful emitted prefix" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    var backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) });
    defer backend.deinit();
    var bridge = Bridge.init(t.allocator, backend.io(), &cancel);
    defer bridge.deinit();
    const host_ = bridge.host();

    // 两条整事件占去三分之二预算，只剩两段切片的额度。
    const filler = try t.allocator.alloc(u8, item_budget);
    defer t.allocator.free(filler);
    @memset(filler, 'f');
    try host_.emit_fn(host_.context, .{ .text = filler }, &cancel);
    try host_.emit_fn(host_.context, .{ .text = filler }, &cancel);
    try t.expectEqual(2 * item_budget, progress(&bridge).bytes);

    const body = try t.allocator.alloc(u8, 3 * item_budget);
    defer t.allocator.free(body);
    @memset(body, 'b');

    const CancelAfterTwo = struct {
        cancel: *p.Cancellation,
        count: usize = 0,
        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            if (self.count == 2) self.cancel.cancel();
        }
    };
    var delivered: CancelAfterTwo = .{ .cancel = &cancel };
    bridge.notification = .{ .context = &delivered, .notify_fn = CancelAfterTwo.notify };
    try t.expectError(error.Canceled, host_.emit_fn(host_.context, .{ .text = body }, &cancel));
    try t.expectEqual(@as(usize, 2), delivered.count);

    for (0..2) |_| {
        var item = bridge.pop().?;
        defer item.deinit();
        try t.expect(item.event == .text);
        try t.expect(std.mem.eql(u8, item.event.text, filler));
    }
    var prefix: usize = 0;
    while (bridge.pop()) |value| {
        var item = value;
        defer item.deinit();
        try t.expect(item.event == .text);
        try t.expect(prefix + item.event.text.len <= body.len);
        try t.expect(std.mem.eql(u8, item.event.text, body[prefix..][0..item.event.text.len]));
        prefix += item.event.text.len;
    }
    // 已入队的只是真实前缀，既没有伪造“已完整”的尾部，也没有截断标记。
    try t.expectEqual(2 * item_budget, prefix);
    try t.expectEqual(@as(usize, 0), progress(&bridge).bytes);
    try t.expectEqual(@as(usize, 0), progress(&bridge).outstanding);
}
test "terminal follows every split part and is never queued behind them" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(t.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    const host_ = bridge.host();
    const body = try multibyteBody(t.allocator);
    defer t.allocator.free(body);

    try host_.emit_fn(host_.context, .{ .text = body }, &cancel);
    // 终态优先级不变：finished 不排队、不占预算，也不等待正文切片被消费。
    try host_.emit_fn(host_.context, .{ .finished = .{ .status = .success } }, &cancel);
    try t.expectEqual(@as(usize, 4), progress(&bridge).len);
    try t.expectEqual(@as(usize, body.len), progress(&bridge).bytes);
    const terminal = bridge.takeTerminal().?;
    try t.expectEqual(r.Status.success, terminal.status);

    const drained = try drainBody(&bridge, body, .text);
    try t.expectEqual(@as(usize, 4), drained.parts);
    try t.expectEqual(body.len, drained.bytes);
}
fn sendNumber(bridge: *Bridge, n: usize, cancel: *p.Cancellation) !void {
    var buf: [4]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d:0>4}", .{n});
    const host_ = bridge.host();
    try host_.emit_fn(host_.context, .{ .text = text }, cancel);
    @memset(&buf, 'x');
}

fn popNumber(bridge: *Bridge, n: usize) !void {
    var item = bridge.pop() orelse return error.MissingItem;
    defer item.deinit();
    var buf: [4]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{d:0>4}", .{n});
    try std.testing.expect(item.event == .text);
    try std.testing.expectEqualStrings(expected, item.event.text);
    try std.testing.expectEqual(@as(usize, 4), item.storage.len);
    try std.testing.expect(item.owner == bridge);
}

test "large queue retains FIFO ownership across compaction and reuse" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(t.allocator, t.io, &cancel);
    defer bridge.deinit();

    for (0..1200) |i| try sendNumber(&bridge, i, &cancel);
    try t.expectEqual(Progress{ .len = 1200, .bytes = 4800, .outstanding = 1200 }, progress(&bridge));
    for (0..100) |i| try popNumber(&bridge, i);
    try t.expectEqual(@as(usize, 100), bridge.head);
    for (1200..1300) |i| try sendNumber(&bridge, i, &cancel);
    for (100..700) |i| try popNumber(&bridge, i);
    try t.expect(bridge.head < 100); // At least one compaction occurred.
    for (1300..1400) |i| try sendNumber(&bridge, i, &cancel);
    try t.expectEqual(Progress{ .len = 700, .bytes = 2800, .outstanding = 700 }, progress(&bridge));
    for (700..1400) |i| try popNumber(&bridge, i);
    try t.expect(bridge.pop() == null);
    try t.expectEqual(Progress{ .len = 0, .bytes = 0, .outstanding = 0 }, progress(&bridge));
    try bridge.reset();
    try sendNumber(&bridge, 42, &cancel);
    try popNumber(&bridge, 42);
    try bridge.reset();
}

test "held popped item keeps reset busy and live queue is freed on deinit" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(t.allocator, t.io, &cancel);
    defer bridge.deinit();
    for (0..8) |i| try sendNumber(&bridge, i, &cancel);
    var held = bridge.pop().?;
    defer held.deinit();
    for (1..6) |i| try popNumber(&bridge, i);
    try t.expectEqual(Progress{ .len = 2, .bytes = 12, .outstanding = 3 }, progress(&bridge));
    try t.expectError(error.Busy, bridge.reset());
    try t.expectEqualStrings("0000", held.event.text);
    for (6..8) |i| try popNumber(&bridge, i);
    try t.expectEqual(Progress{ .len = 0, .bytes = 4, .outstanding = 1 }, progress(&bridge));
    try t.expectError(error.Busy, bridge.reset());
    try sendNumber(&bridge, 8, &cancel);
    try sendNumber(&bridge, 9, &cancel);
    // held is released first by defer; bridge.deinit drains the remaining live items.
}

test "small allocation failures leave queued ownership unchanged" {
    const t = std.testing;
    for (0..3) |fail_index| {
        var cancel: p.Cancellation = .{};
        var backing = t.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        var bridge = Bridge.init(backing.allocator(), t.io, &cancel);
        defer bridge.deinit();
        const host_ = bridge.host();
        if (fail_index == 2) {
            try host_.emit_fn(host_.context, .{ .text = "one" }, &cancel);
            try t.expectError(error.OutOfMemory, host_.emit_fn(host_.context, .{ .text = "two" }, &cancel));
            try t.expectEqual(Progress{ .len = 1, .bytes = 3, .outstanding = 1 }, progress(&bridge));
            var item = bridge.pop().?;
            defer item.deinit();
            try t.expectEqualStrings("one", item.event.text);
            try t.expectError(error.Busy, bridge.reset());
        } else {
            try t.expectError(error.OutOfMemory, host_.emit_fn(host_.context, .{ .text = "one" }, &cancel));
            try t.expectEqual(Progress{ .len = 0, .bytes = 0, .outstanding = 0 }, progress(&bridge));
            try bridge.reset();
        }
    }
}

test "allocation failure mid-body keeps the emitted prefix and returns the reservation" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    // 第二段的分配失败：第一段已入队，失败段的预留预算必须原额归还。
    var backing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 2 });
    var bridge = Bridge.init(backing.allocator(), std.testing.io, &cancel);
    defer bridge.deinit();
    const host_ = bridge.host();

    const body = try t.allocator.alloc(u8, 3 * item_budget);
    defer t.allocator.free(body);
    @memset(body, 'a');

    try t.expectError(error.OutOfMemory, host_.emit_fn(host_.context, .{ .text = body }, &cancel));
    try t.expectEqual(@as(usize, 1), progress(&bridge).len);
    try t.expectEqual(item_budget, progress(&bridge).bytes);

    const drained = try drainBody(&bridge, body[0..item_budget], .text);
    try t.expectEqual(@as(usize, 1), drained.parts);
    try t.expectEqual(@as(usize, 0), progress(&bridge).bytes);
    try t.expectEqual(@as(usize, 0), progress(&bridge).outstanding);
}
test "large tool result display copy is clipped without touching canonical text" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(t.allocator, t.io, &cancel);
    defer bridge.deinit();
    const host_ = bridge.host();

    const big = try t.allocator.alloc(u8, item_budget + 17);
    defer t.allocator.free(big);
    @memset(big, 'x');
    try host_.emit_fn(host_.context, .{ .tool_result = .{
        .id = 1,
        .name = "bash",
        .result = .{ .text = big },
    } }, &cancel);
    @memset(big, 'z');

    var item = bridge.pop().?;
    defer item.deinit();
    try t.expect(item.display_truncated);
    try t.expectEqual(@as(usize, item_budget), item.event.tool_result.result.text.len);
    try t.expectEqual(@as(u8, 'x'), item.event.tool_result.result.text[0]);
    try t.expect(std.unicode.utf8ValidateSlice(item.event.tool_result.result.text));
}
