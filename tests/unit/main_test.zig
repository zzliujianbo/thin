test "resume exit persistence honors late signals without masking prior failures" {
    try std.testing.expectEqual(@as(u8, 0), exitCodeAfterRecording(0, 0));
    try std.testing.expectEqual(@as(u8, 130), exitCodeAfterRecording(0, 2));
    try std.testing.expectEqual(@as(u8, 143), exitCodeAfterRecording(0, 15));
    try std.testing.expectEqual(@as(u8, 1), exitCodeAfterRecording(1, 15));
}
test "interactive tty gate excludes print daemon and worker modes" {
    const id = "0123456789abcdef0123456789abcdef";
    const socket = "/run/user/1000/thin/workers/session.sock";

    try std.testing.expect(requiresInteractiveTty(try cli.parse(&.{"thin"})));
    try std.testing.expect(requiresInteractiveTty(try cli.parse(&.{ "thin", "--resume", id })));
    try std.testing.expect(requiresInteractiveTty(try cli.parse(&.{ "thin", "--connect" })));
    try std.testing.expect(requiresInteractiveTty(try cli.parse(&.{ "thin", "--attach", id })));

    // 无 TTY 也必须能进入：一次性输出、守护服务与内部 worker。
    try std.testing.expect(!requiresInteractiveTty(try cli.parse(&.{ "thin", "--print", "go" })));
    try std.testing.expect(!requiresInteractiveTty(try cli.parse(&.{ "thin", "--daemon" })));
    try std.testing.expect(!requiresInteractiveTty(try cli.parse(&.{ "thin", "--internal-worker", socket, id, "daemon" })));
    try std.testing.expect(!requiresInteractiveTty(try cli.parse(&.{ "thin", "--internal-worker", socket, id, "foreground", "--worker-resume" })));
}
