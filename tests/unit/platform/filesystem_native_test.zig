test "filesystem errno mapping uses the target libc constants" {
    const t = std.testing;
    try t.expectEqual(error.SymlinkNotAllowed, mapError(.LOOP));
    try t.expectEqual(error.FileNotFound, mapError(.NOENT));
    try t.expectEqual(error.PathAlreadyExists, mapError(.EXIST));
    try t.expectEqual(error.AccessDenied, mapError(.ACCES));
    try t.expectEqual(error.AccessDenied, mapError(.PERM));
    try t.expectEqual(error.NotDir, mapError(.NOTDIR));
    try t.expectEqual(error.IsDir, mapError(.ISDIR));
    try t.expectEqual(error.NameTooLong, mapError(.NAMETOOLONG));
    try t.expectEqual(error.NoSpaceLeft, mapError(.NOSPC));
    try t.expectEqual(error.FileSystemError, mapError(.IO));
}
test "filesystem identity never equates an inode on different devices" {
    const original: Identity = .{ .device = 1, .inode = 42 };
    try std.testing.expect(original.eql(original));
    try std.testing.expect(!original.eql(.{ .device = 2, .inode = 42 }));
    try std.testing.expect(!original.eql(.{ .device = 1, .inode = 43 }));
}
