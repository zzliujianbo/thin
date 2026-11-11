const test_command: decision.Input = .{ .command = .{ .command = "sleep 1" } };

const test_refine: decision.Input = .{ .refine_outputs = &.{.{ .id = "original-ID", .text = "first\ntick\nprogress 9%\nERROR /src/foo.zig:12 version 1.2\nlast\n" }} };

fn commandBody(a: Allocator, ask: f64) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{ .answers = .{
        .ask = .{ .type = "noul", .noul = ask },
    } }, .{});
}
