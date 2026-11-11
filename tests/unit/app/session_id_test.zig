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
