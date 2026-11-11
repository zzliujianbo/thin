test "configuration comparison retains echo and canonical flags" {
    const original = std.mem.zeroes(std.c.tc_lflag_t);
    var changed = original;
    changed.ICANON = true;
    try std.testing.expect(!std.meta.eql(configuredLocalFlags(original), configuredLocalFlags(changed)));
    changed = original;
    changed.ECHO = true;
    try std.testing.expect(!std.meta.eql(configuredLocalFlags(original), configuredLocalFlags(changed)));
    if (comptime builtin.os.tag == .macos) {
        changed = original;
        changed.PENDIN = true;
        try std.testing.expectEqual(configuredLocalFlags(original), configuredLocalFlags(changed));
    }
}
test "libc terminal attributes stay inside explicit ABI canaries" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    defer _ = std.c.close(master);
    defer _ = std.c.close(slave);

    // Any libc write past the target struct changes this trailing canary.
    const Guarded = extern struct { value: Termios, canary: [32]u8 };
    var guarded: Guarded = .{ .value = undefined, .canary = @splat(0xa7) };

    try std.testing.expectEqual(@as(c_int, 0), tcgetattr(slave, &guarded.value));
    const marker: [32]u8 = @splat(0xa7);
    try std.testing.expectEqualSlices(u8, &marker, &guarded.canary);

    // 保存原始属性，用于测试结束前恢复终端状态，并逐字段比较 round trip 结果。
    const original = guarded.value;
    cfmakeraw(&guarded.value);
    try std.testing.expectEqualSlices(u8, &marker, &guarded.canary);
    try std.testing.expectEqual(@as(c_int, 0), tcsetattr(slave, .NOW, &guarded.value));
    try std.testing.expectEqual(@as(c_int, 0), tcsetattr(slave, .NOW, &original));
    try std.testing.expectEqual(@as(c_int, 0), tcgetattr(slave, &guarded.value));
    try std.testing.expectEqualSlices(u8, &marker, &guarded.canary);

    try std.testing.expectEqual(original.iflag, guarded.value.iflag);
    try std.testing.expectEqual(original.oflag, guarded.value.oflag);
    try std.testing.expectEqual(original.cflag, guarded.value.cflag);
    try std.testing.expectEqual(configuredLocalFlags(original.lflag), configuredLocalFlags(guarded.value.lflag));
    try std.testing.expectEqualSlices(u8, &original.cc, &guarded.value.cc);
    try std.testing.expectEqual(original.ispeed, guarded.value.ispeed);
    try std.testing.expectEqual(original.ospeed, guarded.value.ospeed);
}
