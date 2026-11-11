test "bounded lexical preflight rejects depth, complexity and unbalanced input" {
    try bound("{\"a\":[1,2]}", 64, 16);
    try std.testing.expectError(error.MetadataTooLarge, bound("{}", 1, 16));
    try std.testing.expectError(error.MetadataTooComplex, bound("[1,2,3]", 64, 2));
    try std.testing.expectError(error.InvalidMetadata, bound("{]", 64, 16));
    try std.testing.expectError(error.InvalidMetadata, bound("{\"x\":\"open", 64, 16));
    var deep: [max_depth + 1]u8 = undefined;
    @memset(deep[0..max_depth], '[');
    deep[max_depth] = '[';
    try std.testing.expectError(error.MetadataTooDeep, bound(&deep, 64, 1000));
}
