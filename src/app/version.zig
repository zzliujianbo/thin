//! Thin's own development version, shared by --version and the startup banner.
//! Increment here for application releases; it is independent of the compiler.
pub const number = "0.1.0-dev";
pub const text = "thin " ++ number;

test "version identifies Thin rather than the compiler" {
    const std = @import("std");
    try std.testing.expectEqualStrings("thin 0.1.0-dev", text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Zig") == null);
}
