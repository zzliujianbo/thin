test "body append keeps all bytes and stops at semantic ownership and size barriers" {
    const a = std.testing.allocator;
    var body = try ownEvent(a, 7, .{ .text = "" });
    defer body.deinit();
    var next = try ownEvent(a, 7, .{ .text = "中🙂" });
    defer next.deinit();
    for (0..1600) |_| try std.testing.expect(try body.appendText(&next, max_item_bytes));
    try std.testing.expectEqual(@as(usize, 1600 * "中🙂".len), body.event.text.len);
    var offset: usize = 0;
    while (offset < body.event.text.len) : (offset += "中🙂".len)
        try std.testing.expectEqualStrings("中🙂", body.event.text[offset..][0.."中🙂".len]);
    const len = body.event.text.len;
    try std.testing.expect(!try body.appendText(&next, len));
    next.epoch = 8;
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    next.epoch = 7;
    next.history_replay = true;
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    next.history_replay = false;
    next.history_reset = true;
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    next.history_reset = false;
    next.history_display_reset = true;
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    next.history_display_reset = false;
    next.display_truncated = true;
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    next.display_truncated = false;
    next.canonical_complete = false;
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    next.canonical_complete = true;
    const reasoning_bytes = next.event.text;
    next.event = .{ .reasoning = reasoning_bytes };
    try std.testing.expect(!try body.appendText(&next, max_item_bytes));
    var thought = try ownEvent(a, 7, .{ .reasoning = "think:" });
    defer thought.deinit();
    try std.testing.expect(try thought.appendText(&next, max_item_bytes));
    try std.testing.expectEqualStrings("think:中🙂", thought.event.reasoning);
    try std.testing.expectEqual(len, body.event.text.len);

    // A held CR is a raw-source boundary: merging either side would hide the
    // earlier event's own sequence from selective ACK proof.
    var cr_head = try ownEvent(a, 7, .{ .text = "line\r" });
    defer cr_head.deinit();
    var cr_tail = try ownEvent(a, 7, .{ .text = "\nnext" });
    defer cr_tail.deinit();
    try std.testing.expect(!try cr_head.appendText(&cr_tail, max_item_bytes));
    try std.testing.expectEqualStrings("line\r", cr_head.event.text);
    try std.testing.expectEqualStrings("\nnext", cr_tail.event.text);
    var plain_head = try ownEvent(a, 7, .{ .text = "plain" });
    defer plain_head.deinit();
    var cr_inside = try ownEvent(a, 7, .{ .text = "a\rb" });
    defer cr_inside.deinit();
    try std.testing.expect(!try plain_head.appendText(&cr_inside, max_item_bytes));
    try std.testing.expectEqualStrings("plain", plain_head.event.text);
}
test "live body append retains latest delivery sequence and rejects barriers" {
    const a = std.testing.allocator;
    var first = try ownEvent(a, 1, .{ .text = "a" });
    defer first.deinit();
    var second = try ownEvent(a, 1, .{ .text = "b" });
    defer second.deinit();
    first.delivery_epoch = 2;
    first.delivery_sequence = 10;
    second.delivery_epoch = 3;
    second.delivery_sequence = 11;
    try std.testing.expect(!try first.appendText(&second, max_item_bytes));
    second.delivery_epoch = 2;
    second.delivery_sequence = 0;
    try std.testing.expect(!try first.appendText(&second, max_item_bytes));
    second.delivery_sequence = 9;
    try std.testing.expect(!try first.appendText(&second, max_item_bytes));
    second.delivery_sequence = 11;
    try std.testing.expect(try first.appendText(&second, max_item_bytes));
    try std.testing.expectEqual(@as(u64, 11), first.delivery_sequence);
    // The merged item starts at its own first live position, not at 11.
    try std.testing.expectEqual(@as(u64, 10), first.delivery_first_sequence);
    try std.testing.expectEqualStrings("ab", first.event.text);
}
test "coalesced live spans keep every raw sequence and refuse gaps or overlaps" {
    const a = std.testing.allocator;
    var span = try ownEvent(a, 1, .{ .reasoning = "r2" });
    defer span.deinit();
    span.delivery_epoch = 4;
    span.delivery_sequence = 2;
    span.delivery_first_sequence = 2;
    var initial = try ownEvent(a, 1, .{ .text = "x" });
    defer initial.deinit();
    try std.testing.expectEqual(@as(u64, 0), initial.delivery_first_sequence);
    var next = try ownEvent(a, 1, .{ .reasoning = "r3" });
    defer next.deinit();
    next.delivery_epoch = 4;
    next.delivery_sequence = 3;
    next.delivery_first_sequence = 3;
    try std.testing.expect(try span.appendText(&next, max_item_bytes));
    try std.testing.expectEqual(@as(u64, 2), span.delivery_first_sequence);
    try std.testing.expectEqual(@as(u64, 3), span.delivery_sequence);
    try std.testing.expectEqualStrings("r2r3", span.event.reasoning);
    // A gap (5) and an overlap (3) are refused; only contiguous raw coverage
    // coalesces. A single event that omits `first` falls back to its sequence.
    next.delivery_sequence = 5;
    next.delivery_first_sequence = 5;
    try std.testing.expect(!try span.appendText(&next, max_item_bytes));
    next.delivery_sequence = 3;
    next.delivery_first_sequence = 3;
    try std.testing.expect(!try span.appendText(&next, max_item_bytes));
    next.delivery_sequence = 4;
    next.delivery_first_sequence = 0;
    try std.testing.expect(try span.appendText(&next, max_item_bytes));
    try std.testing.expectEqual(@as(u64, 2), span.delivery_first_sequence);
    try std.testing.expectEqual(@as(u64, 4), span.delivery_sequence);
    // A different epoch never merges, so a span cannot cross authority.
    next.delivery_epoch = 5;
    next.delivery_sequence = 5;
    next.delivery_first_sequence = 5;
    try std.testing.expect(!try span.appendText(&next, max_item_bytes));
}
test "body append allocation failure preserves both owned inputs" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2, .resize_fail_index = 0 });
    const a = failing.allocator();
    var first = try ownEvent(a, 1, .{ .text = "first" });
    defer first.deinit();
    var second = try ownEvent(a, 1, .{ .text = "second" });
    defer second.deinit();
    try std.testing.expectError(error.OutOfMemory, first.appendText(&second, max_item_bytes));
    try std.testing.expectEqualStrings("first", first.event.text);
    try std.testing.expectEqualStrings("second", second.event.text);
}
test "setConfirming is optional and refuses without an adapter" {
    var vt: VTable = .{
        .snapshot_fn = undefined,
        .submit_fn = undefined,
        .poll_fn = undefined,
        .cancel_fn = undefined,
        .cancel_clear_fn = undefined,
        .approve_fn = undefined,
        .enqueue_fn = undefined,
        .withdraw_fn = undefined,
        .queue_resume_fn = undefined,
        .manage_fn = undefined,
        .detach_fn = undefined,
    };
    var context: u8 = 0;
    const client: Client = .{ .context = &context, .vtable = &vt };
    try std.testing.expectError(error.Unsupported, client.setConfirming(1, true));
}
test "background completion and tool caption are copied by value" {
    const a = std.testing.allocator;
    const bg = @import("../core/background_status.zig");
    var terminal: bg.Terminal = .{ .id = bg.Id.from("job-1"), .command = bg.Command.from("echo ok"), .result = .success, .duration_ms = 9 };
    var item = try ownEvent(a, 1, .{ .background_completed = terminal });
    defer item.deinit();
    @memset(&terminal.command.bytes, 'x');
    try std.testing.expectEqualStrings("echo ok", item.event.background_completed.command.slice());
    var caption: bg.Caption = .{ .action = .start, .command = bg.Command.from("sleep 1") };
    var view = try ownEvent(a, 1, .{ .tool_view = .{ .key = .{ .generation = 1, .index = 0 }, .name = "bash", .display = caption } });
    defer view.deinit();
    @memset(&caption.command.?.bytes, 'x');
    try std.testing.expectEqualStrings("sleep 1", view.event.tool_view.display.?.command.?.slice());
}
test "memory completion owns its summary and is a text coalescing barrier" {
    const a = std.testing.allocator;
    const memory = @import("../core/memory_status.zig");
    var terminal: memory.Terminal = .{ .id = 0, .result = .saved, .saved_count = 1 };
    terminal.summary.append("owned 中文");
    var before = try ownEvent(a, 1, .{ .text = "before" });
    defer before.deinit();
    var item = try ownEvent(a, 1, .{ .memory_completed = terminal });
    defer item.deinit();
    var after = try ownEvent(a, 1, .{ .text = "after" });
    defer after.deinit();
    before.delivery_epoch = 1;
    before.delivery_sequence = 1;
    item.delivery_epoch = 1;
    item.delivery_sequence = 2;
    after.delivery_epoch = 1;
    after.delivery_sequence = 3;
    @memset(&terminal.summary.buf, 'x');
    try std.testing.expectEqualStrings("owned 中文", item.event.memory_completed.summary.text());
    try std.testing.expect(!try before.appendText(&item, max_item_bytes));
    try std.testing.expect(!try item.appendText(&after, max_item_bytes));
    try std.testing.expect(!try before.appendText(&after, max_item_bytes));
    try std.testing.expectEqualStrings("before", before.event.text);
    try std.testing.expectEqual(@as(u64, 2), item.delivery_sequence);
}
test "owned events deep-copy text and drop local inbox pointers" {
    const a = std.testing.allocator;
    var description = [_]u8{ 'd', 'e', 's', 'c' };
    var local_inbox: r.Inbox = .{};
    var item = try ownEvent(a, 7, .{ .permission = .{ .id = 3, .tool_name = "bash", .description = &description, .interrupt = &local_inbox } });
    defer item.deinit();
    @memset(&description, 'x');
    try std.testing.expectEqual(@as(u64, 7), item.epoch);
    try std.testing.expectEqual(@as(u64, 3), item.event.permission.id);
    try std.testing.expectEqualStrings("desc", item.event.permission.description);
    try std.testing.expect(item.event.permission.interrupt == null);
}
test "subagent tool progress owns decoded text after document release" {
    const a = std.testing.allocator;
    var item: Item = undefined;
    {
        var frame = "\"进度\\n完成\"".*;
        var doc = try std.json.parseFromSlice([]const u8, a, &frame, .{ .allocate = .alloc_always });
        defer doc.deinit();
        item = try ownEvent(a, 9, .{ .tool_view = .{
            .key = .{ .generation = 42, .index = 3 },
            .name = "subagent",
            .fields = .{ .id = .{ .text = "job-7" } },
            .subagent_progress = doc.value,
        } });
        @memset(&frame, 'x');
        @memset(@constCast(doc.value), 'x');
    }
    defer item.deinit();
    try std.testing.expectEqualStrings("进度\n完成", item.event.tool_view.subagent_progress.?);
    try std.testing.expectEqualStrings("job-7", item.event.tool_view.fields.id.?.text);
    try std.testing.expectEqual(@as(u64, 42), item.event.tool_view.key.generation);
    try std.testing.expectEqual(@as(usize, 3), item.event.tool_view.key.index);

    var empty = try ownEvent(a, 9, .{ .tool_view = .{ .key = .{ .generation = 1, .index = 0 }, .name = "subagent" } });
    defer empty.deinit();
    try std.testing.expect(empty.event.tool_view.subagent_progress == null);
}
test "user committed event owns complete large input" {
    const a = std.testing.allocator;
    const input = try a.alloc(u8, 65537);
    defer a.free(input);
    @memset(input, 'x');
    var item = try ownEvent(a, 1, .{ .user_committed = .{ .id = 1, .text = input } });
    defer item.deinit();
    @memset(input, 'y');
    try std.testing.expectEqual(@as(usize, 65537), item.event.user_committed.text.len);
    try std.testing.expectEqual(@as(u8, 'x'), item.event.user_committed.text[65536]);
    try std.testing.expect(!item.display_truncated);
}
test "owned events retain large text and every assistant block" {
    const a = std.testing.allocator;
    const text = try a.alloc(u8, 65537);
    defer a.free(text);
    @memset(text, 'q');
    const blocks = try a.alloc(p.Block, 257);
    defer a.free(blocks);
    @memset(blocks, .{ .text = "short" });
    blocks[256] = .{ .text = text };
    var item = try ownEvent(a, 1, .{ .assistant_committed = blocks });
    defer item.deinit();
    @memset(text, 'z');
    try std.testing.expectEqual(@as(usize, 257), item.event.assistant_committed.len);
    try std.testing.expectEqual(@as(usize, 65537), item.event.assistant_committed[256].text.len);
    try std.testing.expectEqual(@as(u8, 'q'), item.event.assistant_committed[256].text[65536]);
    try std.testing.expect(item.canonical_complete and !item.display_truncated);
}
test "owned assistant blocks retain canonical text" {
    const a = std.testing.allocator;
    var text = [_]u8{ 'a', 'b', 'c' };
    const blocks = [_]p.Block{ .{ .text = &text }, .{ .reasoning = "why" } };
    var item = try ownEvent(a, 1, .{ .assistant_committed = &blocks });
    defer item.deinit();
    @memset(&text, 'z');
    try std.testing.expectEqual(@as(usize, 2), item.event.assistant_committed.len);
    try std.testing.expectEqualStrings("abc", item.event.assistant_committed[0].text);
    try std.testing.expectEqualStrings("why", item.event.assistant_committed[1].reasoning);
    try std.testing.expect(item.canonical_complete);
    try std.testing.expect(!item.display_truncated);
}
test "wire failure codes round-trip the details the local TUI classifies" {
    for ([_]anyerror{ error.CleanupFailed, error.UnsafeToContinue, error.InputBudgetExceeded, error.UnknownInputPriceThreshold, error.DecisionUnavailable, error.NoCompactionCandidate }) |err| {
        const code = Failure.fromError(err);
        try std.testing.expectEqual(err, code.toError().?);
    }
    try std.testing.expectEqual(error.RemoteFailure, Failure.fromError(error.SomethingElse).toError().?);
    const terminal = (Terminal{ .status = .canceled, .failure = .canceled }).toRuntime();
    try std.testing.expectEqual(r.Status.canceled, terminal.status);
    try std.testing.expectEqual(error.Canceled, terminal.detail.?);
    try std.testing.expectEqual(@as(?anyerror, null), (Terminal{ .status = .success }).toRuntime().detail);
}
