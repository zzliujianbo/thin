test "read failure captions show the raw error text with hostile bytes sanitized" {
    const a = std.testing.allocator;
    const missing = (try failureReason(a, .read, .{ .text = "FileNotFound", .is_error = true })).?;
    defer a.free(missing);
    try std.testing.expectEqualStrings("FileNotFound", missing);
    const denied = (try failureReason(a, .read, .{ .text = "AccessDenied", .is_error = true })).?;
    defer a.free(denied);
    try std.testing.expectEqualStrings("AccessDenied", denied);
    // The mapper is gone, so an unknown code stays as-is; only control bytes and
    // the line break are sanitized, never replaced by a generic caption.
    const unknown = (try failureReason(a, .read, .{ .text = "\x1b[2JUnknownCode\nprivate-body", .is_error = true })).?;
    defer a.free(unknown);
    try std.testing.expectEqualStrings("\u{fffd}[2JUnknownCode", unknown);
    try std.testing.expect((try failureReason(a, .read, .{ .text = "FileNotFound" })) == null);
    try std.testing.expect((try failureReason(a, .read, .{ .text = "FileNotFound", .is_error = true, .canceled = true })) == null);
}
test "typed tool fields keep unknown targets safe and preserve clipping provenance" {
    const a = std.testing.allocator;
    const missing = try Call.fromFields(a, "write_file", .{});
    defer missing.deinit(a);
    try std.testing.expect(missing.kind == .write and missing.detail == null);
    const path = try Call.fromFields(a, "read_file", .{ .path = .{ .text = "中文\x1b[2J\nfile", .truncated = true } });
    defer path.deinit(a);
    try std.testing.expect(path.truncated and path.kind == .read);
    try std.testing.expect(std.mem.findScalar(u8, path.detail.?, '\x1b') == null);
    try std.testing.expect(std.mem.findScalar(u8, path.detail.?, '\n') == null);
    const command = try Call.fromFields(a, "bash", .{ .path = .{ .text = "wrong" }, .command = .{ .text = "echo hello" } });
    defer command.deinit(a);
    try std.testing.expectEqualStrings("echo hello", command.detail.?);
    const action = try Call.fromFields(a, "memory", .{ .action = .{ .text = "write" } });
    defer action.deinit(a);
    try std.testing.expectEqualStrings("write", action.detail.?);
    const topic = try Call.fromFields(a, "memory", .{ .action = .{ .text = "read" }, .topic = .{ .text = "core" } });
    defer topic.deinit(a);
    try std.testing.expectEqualStrings("read core", topic.detail.?);
    const invalid = try Call.fromFields(a, "memory", .{ .action = .{ .text = "write", .truncated = true }, .topic = .{ .text = "hidden" } });
    defer invalid.deinit(a);
    try std.testing.expect(invalid.detail == null);
}
test "edit call exposes only its path in canonical and typed fields" {
    const a = std.testing.allocator;
    const call = try Call.init(a, "edit_file", "{\"path\":\"source.zig\",\"edits\":[{\"old_text\":\"private-old\",\"new_text\":\"private-new\"}]}");
    defer call.deinit(a);
    try std.testing.expectEqual(Kind.edit, call.kind);
    try std.testing.expectEqualStrings("source.zig", call.detail.?);
    const typed = try Call.fromFields(a, "edit_file", .{ .path = .{ .text = "source.zig" } });
    defer typed.deinit(a);
    try std.testing.expectEqual(Kind.edit, typed.kind);
    try std.testing.expectEqualStrings("source.zig", typed.detail.?);
}
test "memory descriptions include known action and topic without bodies versions or styles" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "read", "write", "delete" }) |action| {
        const args = try std.fmt.allocPrint(a, "{{\"action\":\"{s}\",\"topic\":\"core\",\"content\":\"private-body\",\"expected_version\":\"private-version\"}}", .{action});
        defer a.free(args);
        const call = try Call.init(a, "memory", args);
        defer call.deinit(a);
        const expected = try std.fmt.allocPrint(a, "{s} core", .{action});
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, call.detail.?);
        try std.testing.expect(!call.truncated);
    }
    const list = try Call.init(a, "memory", "{\"action\":\"list\"}");
    defer list.deinit(a);
    try std.testing.expectEqualStrings("list core/index", list.detail.?);
    const unsafe = try Call.init(a, "memory", "{\"action\":\"write\",\"topic\":\"topic\\u001b[2J\\nend\"}");
    defer unsafe.deinit(a);
    try std.testing.expect(std.mem.findScalar(u8, unsafe.detail.?, '\x1b') == null);
    try std.testing.expect(std.mem.findScalar(u8, unsafe.detail.?, '\n') == null);
    for ([_][]const u8{ "{\"action\":\"invented\"}", "{\"action\":\"read\",\"topic\":", "[]" }) |args| {
        const unknown = try Call.init(a, "memory", args);
        defer unknown.deinit(a);
        try std.testing.expect(unknown.detail == null);
    }
    const long_topic: [600]u8 = @splat('a');
    const long_args = try std.fmt.allocPrint(a, "{{\"action\":\"read\",\"topic\":\"{s}\"}}", .{long_topic[0..]});
    defer a.free(long_args);
    const long = try Call.init(a, "memory", long_args);
    defer long.deinit(a);
    try std.testing.expect(long.truncated and long.detail.?.len <= 512);
}
test "bash batch captions count commands without exposing their bodies" {
    const a = std.testing.allocator;
    const two = try Call.init(a, "bash", "{\"commands\":[{\"command\":\"printf one\"},{\"command\":\"printf two\"}]}");
    defer two.deinit(a);
    try std.testing.expect(two.kind == .bash);
    try std.testing.expectEqualStrings("2 commands", two.detail.?);
    const one = try Call.init(a, "bash", "{\"commands\":[{\"command\":\"printf one\"}]}");
    defer one.deinit(a);
    try std.testing.expectEqualStrings("1 command", one.detail.?);
}

test "shared tools expose structured safe detail observations and bounded FIFO without styles" {
    const a = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(a);
    try queue.capture(a, &.{
        .{ .tool_call = .{ .id = "one", .name = "bash", .arguments = "{\"command\":\"date\\n<hello>\\u001b[2J\"}" } },
        .{ .tool_call = .{ .id = "two", .name = "write_file", .arguments = "{\"path\":\"src/main.zig\",\"content\":\"not-display-content\"}" } },
    });
    const one = try queue.take("bash", a);
    defer one.deinit(a);
    try std.testing.expect(std.mem.startsWith(u8, one.detail.?, "date <hello>"));
    try std.testing.expect(std.mem.findScalar(u8, one.detail.?, '\x1b') == null);
    const two = try queue.take("write_file", a);
    defer two.deinit(a);
    try std.testing.expectEqualStrings("src/main.zig", two.detail.?);
    const complete = Completion.fromExecution(.{ .text = "hidden JSON", .file_stats = .{ .changes = .{ .modified = 3, .added = 5, .removed = 2 } } });
    try std.testing.expectEqual(@as(u64, 3), complete.file_stats.?.changes.?.modified);
    try std.testing.expect(Completion.fromExecution(.{ .text = "failed", .is_error = true, .file_stats = complete.file_stats }).file_stats == null);
    const unknown = try Call.init(a, "read_file", "{\"path\":\"partial");
    defer unknown.deinit(a);
    try std.testing.expect(unknown.detail == null);
    try std.testing.expectEqual(Kind.other, Kind.fromName("untrusted\x1b[2J"));
}
