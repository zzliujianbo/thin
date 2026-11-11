test "resume command is one green line after a blank separator with only a validated ID" {
    const id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    const a = std.testing.allocator;
    const line = try format(a, id);
    defer a.free(line);
    try std.testing.expectEqualStrings("\n" ++ theme.success ++ "thin --resume " ++ id ++ theme.reset ++ "\n", line);
    try std.testing.expectError(error.InvalidSessionID, format(a, @splat(';')));
}
