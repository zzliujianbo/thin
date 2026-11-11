test "subagent tool progress allocation failure preserves old caption" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, subagentProgressAllocationScenario, .{});
}
test "subagent tool progress respects generation readiness and ownership" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 7);
    var progress = [_]u8{ 'w', 'o', 'r', 'k' };
    var event: r.ToolView = .{ .key = key(7, 1), .name = "get_subagent_result", .fields = .{ .id = .{ .text = "subagent_1" } }, .ready = true, .subagent_progress = &progress };
    try views.upsert(a, event);
    progress[0] = 'X';
    try std.testing.expectEqualStrings("subagent_1 · work", views.get(event.key).?.caption.label);
    event.ready = false;
    event.subagent_progress = "late";
    try views.upsert(a, event);
    try std.testing.expectEqualStrings("subagent_1 · work", views.get(event.key).?.caption.label);
    event.ready = true;
    event.key = key(8, 1);
    try views.upsert(a, event);
    try std.testing.expect(views.get(event.key) == null);
    event.key = key(7, 2);
    event.name = "read_file";
    event.fields = .{ .path = .{ .text = "file" } };
    try views.upsert(a, event);
    try std.testing.expectEqualStrings("file", views.get(event.key).?.caption.label);
}
test "background ready metadata refreshes one owned row" {
    const a = std.testing.allocator;
    const status = @import("../core/background_status.zig");
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 7);
    var event: r.ToolView = .{ .key = key(7, 1), .name = "bash", .fields = .{ .command = .{ .text = "old" } }, .ready = true };
    try views.upsert(a, event);
    event.display = .{ .action = .start, .command = status.Command.from("sleep 1") };
    try views.upsert(a, event);
    try std.testing.expectEqual(@as(usize, 1), views.entries.items.len);
    const caption = (try views.cloneReadyCaption(a, event.key)).?;
    defer caption.deinit(a);
    try std.testing.expectEqualStrings("▶ sleep 1", caption.label);
    try std.testing.expect(caption.display.?.action == .start);
    const line = try presentation.commandText(a, caption, .success);
    defer a.free(line);
    try std.testing.expectEqualStrings("B: ▶ sleep 1", line);
    event.display = null;
    event.fields.command = .{ .text = "unguarded preview" };
    try views.upsert(a, event);
    try std.testing.expectEqualStrings("▶ sleep 1", views.get(event.key).?.caption.label);
    const done = try presentation.completed(a, caption, null);
    defer done.deinit(a);
    try std.testing.expect(done.display.?.action == .start);
    const call = @import("../presentation.zig").tools.Call{ .kind = .bash, .detail = "unguarded", .display = caption.display };
    const fallback = try presentation.fromCall(a, call);
    defer fallback.deinit(a);
    try std.testing.expectEqualStrings("▶ sleep 1", fallback.label);
    try std.testing.expect(fallback.display.?.action == .start);
    const completion = @import("../presentation.zig").tools.Completion.fromExecution(.{ .text = "ok", .duration_ms = 22, .display = caption.display });
    try std.testing.expect(completion.duration_ms == null);
}
test "tool views same key updates in place and same names remain distinct" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 7);
    var label = [_]u8{ 'o', 'n', 'e' };
    try views.upsert(a, view(7, 12, &label, false));
    label[0] = 'X';
    try std.testing.expectEqualStrings("one", views.get(key(7, 12)).?.caption.label);
    const first = views.get(key(7, 12)).?;
    try views.upsert(a, view(7, 12, "new", false));
    try std.testing.expect(first == views.get(key(7, 12)).?);
    try std.testing.expectEqualStrings("new", first.caption.label);
    try views.upsert(a, view(7, 2, "other", false));
    try std.testing.expectEqual(@as(usize, 2), views.entries.items.len);
    try std.testing.expectEqualStrings("new", views.get(key(7, 12)).?.caption.label);
    try std.testing.expectEqualStrings("other", views.get(key(7, 2)).?.caption.label);
}
test "tool views require explicit begin and ignore stale generations and discard" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    try views.upsert(a, view(1, 0, "ignored", true));
    try std.testing.expectEqual(@as(usize, 0), views.entries.items.len);
    views.begin(a, 1);
    try views.upsert(a, view(1, 0, "old", true));
    const capacity = views.entries.capacity;
    views.begin(a, 2);
    try std.testing.expectEqual(capacity, views.entries.capacity);
    try views.upsert(a, view(2, 0, "new", false));
    views.discard(a, 1);
    views.commit(a, 1);
    try views.upsert(a, view(1, 0, "late", true));
    try std.testing.expect(views.get(key(1, 0)) == null);
    try std.testing.expectEqualStrings("new", views.get(key(2, 0)).?.caption.label);
    views.discard(a, 2);
    try std.testing.expect(views.generation == null);
    try views.upsert(a, view(2, 0, "late after discard", true));
    try std.testing.expectEqual(@as(usize, 0), views.entries.items.len);
}
test "tool views ready resists provisional rollback commit sorts and prunes" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 1);
    try views.upsert(a, view(1, 9, "nine", false));
    try views.upsert(a, view(1, 0, "zero", false));
    try views.upsert(a, view(1, 5, "prune", false));
    try std.testing.expect((try views.cloneReadyCaption(a, key(1, 9))) == null);
    try views.upsert(a, view(1, 0, "first ready", true));
    try views.upsert(a, view(1, 9, "second ready", true));
    try views.upsert(a, view(1, 0, "late provisional", false));
    try views.upsert(a, view(1, 0, "ready update", true));
    try std.testing.expectEqual(@as(usize, 2), views.ready_count);
    views.commit(a, 1);
    try std.testing.expectEqual(@as(usize, 2), views.entries.items.len);
    try std.testing.expect(views.entries.items[0].key.eql(key(1, 0)));
    try std.testing.expect(views.entries.items[1].key.eql(key(1, 9)));
    try std.testing.expectEqualStrings("ready update", views.entries.items[0].caption.label);
    try std.testing.expect(views.get(key(1, 5)) == null);
    views.commit(a, 1);
    try std.testing.expectEqual(@as(usize, 2), views.entries.items.len);
}
test "tool views preserve known write progress across late unknown updates" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 5);
    var known = view(5, 1, "file", false);
    known.name = "write_file";
    known.write_progress = .{ .added = 4, .deleted = 2 };
    try views.upsert(a, known);
    var unknown = known;
    unknown.write_progress = .{};
    try views.upsert(a, unknown);
    try std.testing.expectEqualDeep(@import("../core/write_preview.zig").Progress{ .added = 4, .deleted = 2 }, views.get(key(5, 1)).?.write_progress.?);
    unknown.ready = true;
    try views.upsert(a, unknown);
    try std.testing.expect(views.get(key(5, 1)).?.ready);
    try std.testing.expectEqualDeep(@import("../core/write_preview.zig").Progress{ .added = 4, .deleted = 2 }, views.get(key(5, 1)).?.write_progress.?);
}
test "tool views cloned caption owns label and preserves renderer metadata" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 3);
    try views.upsert(a, view(3, 0, "source", true));
    const marks: presentation.WriteMarks = .{
        .added = .{ .start = 0, .end = 1 },
        .removed = .{ .start = 2, .end = 3 },
    };
    views.entries.items[0].caption.write_marks = marks;
    views.entries.items[0].caption.failure_reason = "static reason";
    const original = views.get(key(3, 0)).?.caption;
    const clone = (try views.cloneReadyCaption(a, key(3, 0))).?;
    defer clone.deinit(a);
    try std.testing.expect(original.label.ptr != clone.label.ptr);
    try std.testing.expectEqual(original.kind, clone.kind);
    try std.testing.expectEqualDeep(original.write_marks, clone.write_marks);
    try std.testing.expectEqualStrings("static reason", clone.failure_reason.?);
    try views.upsert(a, view(3, 0, "replacement", true));
    views.remove(a, key(3, 0));
    try std.testing.expectEqualStrings("source", clone.label);
    try std.testing.expect((try views.cloneReadyCaption(a, key(3, 0))) == null);
    try std.testing.expectEqual(@as(usize, 0), views.ready_count);
}
test "tool views cap ignores only new entries and remove keeps bounded ready order" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 4);
    for (0..limit) |i| try views.upsert(a, view(4, i, "row", true));
    try views.upsert(a, view(4, limit, "ignored", true));
    try std.testing.expectEqual(@as(usize, limit), views.entries.items.len);
    try std.testing.expectEqual(@as(usize, limit), views.ready_count);
    try views.upsert(a, view(4, 0, "updated at cap", true));
    try std.testing.expectEqualStrings("updated at cap", views.get(key(4, 0)).?.caption.label);
    for (0..128) |_| {
        views.remove(a, key(4, 0));
        views.remove(a, key(999, 1));
        try views.upsert(a, view(4, 0, "reinserted", true));
        try std.testing.expectEqual(@as(usize, limit), views.ready_count);
        try std.testing.expectEqual(@as(usize, limit - 1), views.get(key(4, 0)).?.order);
    }
    views.commit(a, 4);
    for (views.entries.items, 0..) |entry, i| try std.testing.expectEqual(i, entry.order);
    views.remove(a, key(4, 0));
    views.remove(a, key(4, 0));
    try std.testing.expectEqual(@as(usize, limit - 1), views.ready_count);
    views.clear(a);
    try std.testing.expect(views.entries.capacity >= limit);
    try std.testing.expect(views.generation == null);
    try std.testing.expectEqual(@as(usize, 0), views.ready_count);
    views.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), views.entries.capacity);
}
test "canonical ready row replaces provisional metadata at the display cap" {
    const a = std.testing.allocator;
    var views: Views = .{};
    defer views.deinit(a);
    views.begin(a, 5);
    for (0..limit) |i| try views.upsert(a, view(5, i, "provisional", false));
    try views.upsert(a, view(5, limit, "authoritative", true));
    try std.testing.expectEqual(@as(usize, limit), views.entries.items.len);
    try std.testing.expect(views.get(key(5, limit)).?.ready);
    try std.testing.expectEqual(@as(usize, 1), views.ready_count);
    views.commit(a, 5);
    try std.testing.expectEqual(@as(usize, 1), views.entries.items.len);
    try std.testing.expectEqualStrings("authoritative", views.entries.items[0].caption.label);
}
test "tool views upsert and clone allocation failures preserve ownership and state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, growthScenario, .{});
}
