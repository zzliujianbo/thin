test "validateQuery rejects cross-action fields" {
    try validateQuery(.{ .action = .list });
    try validateQuery(.{ .action = .list, .after = 3, .limit = 100 });
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .list, .id = "ab-1" }));
    try validateQuery(.{ .action = .list, .limit = 101 });
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .list, .limit = 0 }));
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .list, .stdout_offset = 0 }));

    try validateQuery(.{ .action = .status, .id = "ab-1" });
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .status }));
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .status, .id = "ab-1", .after = 0 }));
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .status, .id = "ab-1", .limit = 20 }));

    try validateQuery(.{ .action = .logs, .id = "ab-1", .stdout_offset = 0, .stderr_offset = 9, .limit = 16384 });
    try validateQuery(.{ .action = .logs, .id = "ab-1", .limit = 16385 });
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .logs, .id = "ab-1", .after = 1 }));

    try validateQuery(.{ .action = .stop, .id = "ab-1" });
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .stop }));
}
test "validId bounds and charset" {
    try testing.expect(validId("0123456789ab-1"));
    try testing.expect(!validId(""));
    try testing.expect(!validId("-1"));
    try testing.expect(!validId("ab-"));
    try testing.expect(!validId("AB-1"));
    try testing.expect(!validId("ab-1-2"));
    try testing.expect(!validId("ab 1"));
    var long_id: [70]u8 = @splat('a');
    long_id[69] = '1';
    try testing.expect(!validId(&long_id));
    var long_sep: [70]u8 = @splat('a');
    long_sep[34] = '-';
    try testing.expect(!validId(&long_sep));
}
test "defaults" {
    try testing.expectEqual(@as(usize, 20), pageLimit(.{ .action = .list }));
    try testing.expectEqual(@as(usize, 100), pageLimit(.{ .action = .list, .limit = 100 }));
    try testing.expectEqual(@as(usize, 4096), logBudget(.{ .action = .logs }));
    try testing.expectEqual(@as(usize, 16384), logBudget(.{ .action = .logs, .limit = 16384 }));
}
test "parseQuery rejects coercion, null fields and duplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // action 必须是字符串枚举名，数值 tag 与数字字符串都不接受。
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":1}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"1\"}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"restart\"}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "[]"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "null"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{"));

    // 数值只接受未加引号的整数原文。
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":\"1\"}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":1.0}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":1e0}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":1.5}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":-1}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"after\":-0}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"after\":18446744073709551616}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"logs\",\"id\":\"0123456789ab-1\",\"stdout_offset\":1.0}"));
    try testing.expectEqual(@as(?usize, 101), (try parseQuery(a, "{\"action\":\"list\",\"limit\":101}")).limit);
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":0}"));

    // null 不等于缺省：无关字段、必填字段、未知字段都拒绝。
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"id\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"status\",\"id\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"status\",\"limit\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"logs\",\"id\":\"0123456789ab-1\",\"after\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"stop\",\"id\":\"0123456789ab-1\",\"stderr_offset\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"unknown\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"status\",\"id\":\"0123456789ab-1\",\"unknown\":null}"));

    // id 只能是字符串，且仍要满足 validId。
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"status\",\"id\":1}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"stop\",\"id\":\"ABCDEF012345-1\"}"));

    // 重复字段必须报错，不得静默采用其中一个。
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"action\":\"list\"}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"after\":1,\"after\":2}"));
}
test "parseQuery accepts strict per-action fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const list = try parseQuery(a, "{\"action\":\"list\"}");
    try testing.expectEqual(Action.list, list.action);
    try testing.expect(list.id == null and list.after == null and list.limit == null);

    const paged = try parseQuery(a, "{\"action\":\"list\",\"after\":3,\"limit\":100}");
    try testing.expectEqual(@as(?u64, 3), paged.after);
    try testing.expectEqual(@as(?usize, 100), paged.limit);

    const status = try parseQuery(a, "{\"action\":\"status\",\"id\":\"0123456789ab-1\"}");
    try testing.expectEqual(Action.status, status.action);
    try testing.expectEqualStrings("0123456789ab-1", status.id.?);
    try testing.expect(status.after == null and status.limit == null);

    const logs = try parseQuery(a, "{\"action\":\"logs\",\"id\":\"0123456789ab-1\",\"stdout_offset\":0,\"stderr_offset\":9,\"limit\":16384}");
    try testing.expectEqual(@as(?u64, 0), logs.stdout_offset);
    try testing.expectEqual(@as(?u64, 9), logs.stderr_offset);
    try testing.expectEqual(@as(?usize, 16384), logs.limit);

    const stop = try parseQuery(a, "{\"action\":\"stop\",\"id\":\"0123456789ab-1\"}");
    try testing.expectEqual(Action.stop, stop.action);
}
test "parseQuery keeps exact u64 cursors without f64" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const paged = try parseQuery(a, "{\"action\":\"list\",\"after\":18446744073709551615}");
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), paged.after);

    const far = try parseQuery(a, "{\"action\":\"logs\",\"id\":\"0123456789ab-1\",\"stdout_offset\":18446744073709551615,\"stderr_offset\":18446744073709551614}");
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), far.stdout_offset);
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64) - 1), far.stderr_offset);
}
