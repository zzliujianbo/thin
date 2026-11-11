test "metadata agrees for owned fd and entry and preserves nofollow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = "abc" });
    const fd = fs.openAt(tmp.dir.handle, "file", .{ .NOFOLLOW = true, .CLOEXEC = true }, 0);
    try std.testing.expect(fd >= 0);
    defer fs.closeFd(fd);
    const opened = try statFd(fd);
    const entry = try statAt(tmp.dir.handle, "file", true);
    try std.testing.expectEqual(opened.ino, entry.ino);
    try std.testing.expectEqual(opened.dev_major, entry.dev_major);
    try std.testing.expectEqual(opened.dev_minor, entry.dev_minor);
    try std.testing.expectEqual(@as(u64, 3), opened.size);
    try std.testing.expectEqual(@as(u32, @intCast(c.geteuid())), opened.uid);
    try std.testing.expectEqual(@as(u64, 1), opened.nlink);
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("file", tmp.dir.handle, "link"));
    try std.testing.expect((try statAt(tmp.dir.handle, "link", true)).mode & c.S.IFMT == c.S.IFLNK);
    try std.testing.expectEqual(opened.ino, (try statAt(tmp.dir.handle, "link", false)).ino);
}
test "system aliases do not canonicalize arbitrary paths or traversal" {
    const a = std.testing.allocator;
    const path = try systemPath(a, "/project/not-a-system-alias");
    defer a.free(path);
    try std.testing.expectEqualStrings("/project/not-a-system-alias", path);
    try std.testing.expectError(error.InvalidPath, systemPath(a, "/tmp/../project"));
    try std.testing.expectError(error.InvalidPath, systemPath(a, "relative"));
}
