test "macOS rejects service modes without interpreting prompt data as flags" {
    if (!local_only) return error.SkipZigTest;
    const cli = @import("../app/cli.zig");
    try validateArgs(&.{ "thin", "--print", "--daemon" });
    try validate(try cli.parse(&.{ "thin", "--print", "--daemon" }));
    try validate(try cli.parse(&.{"thin"}));
    for ([_][]const u8{ "--daemon", "--connect", "--attach", "--takeover", "--ssh-listen", "--internal-ssh" }) |flag| {
        const terminated = try std.testing.allocator.dupeSentinel(u8, flag, 0);
        defer std.testing.allocator.free(terminated);
        try std.testing.expectError(error.UnsupportedPlatformMode, validateArgs(&.{ "thin", terminated }));
    }
    try std.testing.expectError(error.UnsupportedPlatformMode, validate(try cli.parse(&.{ "thin", "--daemon" })));
    const id = "0123456789abcdef0123456789abcdef";
    try validate(try cli.parse(&.{ "thin", "--internal-worker", "/tmp/owned.sock", id, "foreground" }));
    try std.testing.expectError(error.UnsupportedPlatformMode, validate(try cli.parse(&.{ "thin", "--internal-worker", "/tmp/owned.sock", id, "daemon" })));
}
