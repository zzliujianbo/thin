//! Public, value-owned device-login display state. Never contains credentials.

pub const verification_url = "https://auth.openai.com/codex/device";
pub const Action = enum { start, cancel };
pub const Status = enum { idle, pending, succeeded, failed, canceled };
pub const Failure = enum { unavailable, denied, expired, busy, invalid_response, storage, other };

pub const View = struct {
    generation: u64 = 0,
    status: Status = .idle,
    code: [64]u8 = @splat(0),
    code_len: u8 = 0,
    failure: ?Failure = null,

    pub fn userCode(self: *const View) []const u8 {
        return self.code[0..self.code_len];
    }
};

test "default login view owns an empty code" {
    const std = @import("std");
    const view: View = .{};
    try std.testing.expectEqual(Status.idle, view.status);
    try std.testing.expectEqualStrings("", view.userCode());
}
