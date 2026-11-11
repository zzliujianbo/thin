test "interrupt handler records target signal numbers and clear resets state" {
    defer clear();
    clear();
    try std.testing.expectEqual(@as(u8, 0), signal());
    for (signals) |sig| {
        handler(sig);
        try std.testing.expectEqual(@as(u8, @intCast(@backingInt(sig))), signal());
        clear();
        try std.testing.expectEqual(@as(u8, 0), signal());
    }
}
test "interrupt guard restores target libc actions and repeated deinit is safe" {
    var before: [signals.len]c.Sigaction = undefined;
    for (signals, 0..) |sig, i| {
        try std.testing.expectEqual(@as(c_int, 0), c.sigaction(sig, null, &before[i]));
    }
    var guard = try Guard.install();
    defer guard.deinit();
    try std.testing.expectEqual(signals.len, guard.installed);
    for (signals) |sig| {
        var installed: c.Sigaction = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.sigaction(sig, null, &installed));
        try std.testing.expectEqual(@as(?c.Sigaction.handler_fn, handler), installed.handler.handler);
    }
    guard.deinit();
    guard.deinit();
    try std.testing.expectEqual(@as(usize, 0), guard.installed);
    for (signals, 0..) |sig, i| {
        var after: c.Sigaction = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.sigaction(sig, null, &after));
        try std.testing.expectEqual(before[i].handler.handler, after.handler.handler);
        for (signals) |masked| {
            try std.testing.expectEqual(c.sigismember(&before[i].mask, masked), c.sigismember(&after.mask, masked));
        }
    }
}
