test "stream task summary is previewed without the context body" {
    const t = std.testing;
    var c: Controller = .{ .allocator = t.allocator, .generation = 5, .schemas = &.{.{ .name = "subagent", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    const view = c.observe(.{ .index = 0, .name = "subagent", .arguments = "{\"task\":\"check release paths\",\"context\":\"secret-parent-note\"}" }).?;
    try t.expectEqualStrings("check release paths", view.fields.task.?.text);
    try t.expect(view.fields.path == null and view.fields.command == null);
}
test "stream job id is previewed while message body stays hidden" {
    const t = std.testing;
    var c: Controller = .{ .allocator = t.allocator, .generation = 5, .schemas = &.{.{ .name = "send_subagent_message", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    const view = c.observe(.{ .index = 0, .name = "send_subagent_message", .arguments = "{\"id\":\"job-9\",\"message\":\"private-body\"}" }).?;
    try t.expectEqualStrings("job-9", view.fields.id.?.text);
    try t.expect(view.fields.task == null and view.fields.path == null);
}
test "stream links require complete ids and raw arguments" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .allocator = t.allocator, .generation = 7, .schemas = &.{.{ .name = "read_file", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    try t.expect(c.observe(.{ .index = 19, .name = "read_", .arguments = "{\"path\":", .call_id = "one" }) == null);
    const v = c.observe(.{ .index = 19, .name = "read_file", .arguments = "\"a\"}", .call_id = "one" }).?;
    try t.expectEqualStrings("a", v.fields.path.?.text);
    const links = c.links();
    try t.expectEqual(@as(usize, 19), links.lookup("one", "{\"path\":\"a\"}").?.key.index);
    try t.expect(links.lookup("one", "{\"path\":\"b\"}") == null);
    try t.expect(links.lookup("missing", "{\"path\":\"a\"}") == null);
}
test "stream write progress decodes content and binds canonical digest" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .allocator = t.allocator, .generation = 3, .schemas = &.{.{ .name = "write_file", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    const first = c.observe(.{ .index = 2, .name = "write_file", .arguments = "{\"path\":\"x\",\"content\":\"a\\n", .call_id = "w" }).?;
    try t.expect(first.write_progress != null);
    const request = c.takeBaselineRequest(2).?;
    try t.expectEqualStrings("x", request.path);
    _ = c.resolveBaseline(2, try write_preview.Baseline.fromBytes(t.allocator, "old\n"));
    const final = c.observe(.{ .index = 2, .name = "write_file", .arguments = "b\"}", .call_id = "w" }).?;
    try t.expectEqualDeep(write_preview.Progress{ .added = 2, .deleted = 1 }, final.write_progress.?);
    const links = c.links();
    try t.expect(links.lookup("w", "{\"path\":\"x\",\"content\":\"a\\nb\"}") != null);
}
test "stream write invalid duplicate and late identity stay unknown" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .allocator = t.allocator, .generation = 4, .schemas = &.{.{ .name = "write_file", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    _ = c.observe(.{ .index = 1, .name = "", .arguments = "{\"content\":\"lost\"", .call_id = "late" });
    const late = c.observe(.{ .index = 1, .name = "write_file", .arguments = ",\"path\":\"x\"}", .call_id = "late" }).?;
    try t.expect(late.write_progress != null and late.write_progress.?.added == null);

    _ = c.observe(.{ .index = 2, .name = "write_file", .arguments = "{\"path\":\"x\",\"content\":\"a\",", .call_id = "dup" });
    _ = c.resolveBaseline(2, try write_preview.Baseline.fromBytes(t.allocator, ""));
    const duplicate = c.observe(.{ .index = 2, .name = "write_file", .arguments = "\"content\":\"b\"}", .call_id = "dup" }).?;
    try t.expect(duplicate.write_progress.?.added == null);
    const links = c.links();
    try t.expect(links.lookup("late", "{\"content\":\"lost\",\"path\":\"x\"}").?.write_progress.?.added == null);
    try t.expect(links.lookup("dup", "{\"path\":\"x\",\"content\":\"a\",\"content\":\"b\"}").?.write_progress.?.added == null);
}
test "stream write identity revokes when accumulated name changes" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .allocator = t.allocator, .generation = 9, .schemas = &.{.{ .name = "write_file", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    const first = c.observe(.{ .index = 3, .name = "write_file", .arguments = "{\"path\":\"x\",\"content\":\"a", .call_id = "id", .write_file = true }).?;
    try t.expect(first.write_progress != null);
    try t.expect(c.observe(.{ .index = 3, .name = "write_file_other", .arguments = "\"}", .call_id = "id", .write_file = false }) == null);
    const links = c.links();
    try t.expect(links.lookup("id", "{\"path\":\"x\",\"content\":\"a\"}").?.write_progress == null);
}
test "stream final-only keys cannot collide with anonymous preview indices" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .allocator = t.allocator, .generation = 3, .schemas = &.{} };
    defer c.deinit();
    _ = c.observe(.{ .index = 0, .arguments = "{}" });
    const links = c.links();
    try t.expect(links.lookup("final", "{}") == null);
    try t.expectEqual(@as(usize, 1), links.fresh(&.{}).index);
}
test "stream controller caps previews and generations isolate reused indices" {
    const t = std.testing;
    const c = try t.allocator.create(Controller);
    defer t.allocator.destroy(c);
    c.* = .{ .allocator = t.allocator, .generation = 8, .schemas = &.{.{ .name = "bash", .description = "", .parameters_json = "{}" }} };
    defer c.deinit();
    for (0..limit) |index| try t.expect(c.observe(.{ .index = index, .name = "bash", .arguments = "{}" }) != null);
    try t.expect(c.observe(.{ .index = limit, .name = "bash", .arguments = "{}" }) == null);
}
