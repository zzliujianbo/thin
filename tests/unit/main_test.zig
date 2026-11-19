test "interactive tty gate excludes daemon and owned children" {
    const id = "0123456789abcdef0123456789abcdef";
    const socket = "/run/user/1000/thin/workers/session.sock";

    try std.testing.expect((try cli.parse(&.{"thin"})).mode.requiresTty());
    try std.testing.expect(!(try cli.parse(&.{ "thin", "--daemon" })).mode.requiresTty());
    try std.testing.expect(!(try cli.parse(&.{ "thin", "--internal-worker", socket, id, "daemon" })).mode.requiresTty());
    try std.testing.expect(!(try cli.parse(&.{ "thin", "--internal-worker", socket, id, "foreground", "--worker-resume" })).mode.requiresTty());
}
