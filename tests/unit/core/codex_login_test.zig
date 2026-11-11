test "default login view owns an empty code" {
    const std = @import("std");
    const view: View = .{};
    try std.testing.expectEqual(Status.idle, view.status);
    try std.testing.expectEqualStrings("", view.userCode());
}
