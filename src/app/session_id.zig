//! Immutable local identity; generation never creates a session archive.
const std = @import("std");
pub const Id = [32]u8;

pub fn generate(io: std.Io) !Id {
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    return std.fmt.bytesToHex(random, .lower);
}

pub fn valid(id: Id) bool {
    for (id) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    return true;
}

test "session identity is fixed lowercase hex not terminal text" {
    const id = try generate(std.testing.io);
    try std.testing.expect(valid(id));
    const zero: Id = @splat('0');
    try std.testing.expect(valid(zero));
    var invalid = zero;
    invalid[0] = 'A';
    try std.testing.expect(!valid(invalid));
    invalid[0] = '\n';
    try std.testing.expect(!valid(invalid));
}
