test "startup shows Thin version safe directory and local timezone offset" {
    const a = std.testing.allocator;
    try @import("text.zig").initLocale();
    const value = try banner(a, "/tmp/project\nspoof\t\x1b[31m", 0);
    defer a.free(value);
    try std.testing.expect(std.mem.startsWith(u8, value, version.text ++ "\n/tmp/project spoof "));
    try std.testing.expect(std.mem.find(u8, value, "Directory: ") == null);
    try std.testing.expect(std.mem.find(u8, value, "Time: ") == null);
    try std.testing.expect(value[value.len - 5] == '+' or value[value.len - 5] == '-');
    for (value[value.len - 4 ..]) |digit| try std.testing.expect(digit >= '0' and digit <= '9');
    try std.testing.expect(std.mem.findScalar(u8, value, 0x1b) == null);
    try std.testing.expect(std.mem.find(u8, value, "Zig") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, value, "\n"));
    // Focused runs supply these POSIX TZ values externally; never mutate the
    // process-wide timezone while I/O threads may exist.
    if (getenv("TZ")) |zone| {
        if (std.mem.eql(u8, std.mem.span(zone), "UTC0"))
            try std.testing.expect(std.mem.endsWith(u8, value, "1970-01-01 00:00:00 +0000"));
        if (std.mem.eql(u8, std.mem.span(zone), "UTC-8"))
            try std.testing.expect(std.mem.endsWith(u8, value, "1970-01-01 08:00:00 +0800"));
    }
    const unavailable = try banner(a, "/project", -1);
    defer a.free(unavailable);
    try std.testing.expect(std.mem.eql(u8, unavailable, version.text ++ "\n/project\nunavailable"));
}
