test "platform gating follows syntax and preserves macOS local workers" {
    const testing = @import("std").testing;
    const id = "0123456789abcdef0123456789abcdef";
    try validate(try cli.parse(&.{"thin"}));
    try validate(try cli.parse(&.{ "thin", "--internal-worker", "/tmp/owned.sock", id, "foreground" }));
    for ([_][]const [:0]const u8{
        &.{ "thin", "--daemon" },
        &.{ "thin", "--internal-worker", "/tmp/owned.sock", id, "daemon" },
    }) |args| {
        const options = try cli.parse(args);
        if (local_only) {
            try testing.expectError(error.UnsupportedPlatformMode, validate(options));
        } else {
            try validate(options);
        }
    }
}
