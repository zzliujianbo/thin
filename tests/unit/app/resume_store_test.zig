test "resume save classification waits for the worker result" {
    try classifySave(true, null);
    try std.testing.expectError(error.ResumeConflict, classifySave(true, error.ResumeConflict));
    try std.testing.expectError(error.Canceled, classifySave(true, error.Canceled));
    try std.testing.expectError(error.ResumeSaveTimeout, classifySave(false, null));
    try std.testing.expectError(error.ResumeSaveTimeout, classifySave(false, error.ResumeConflict));
}
test "resume listing is read only sorted and ignores invalid entries" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const empty = try list(&root, a);
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));

    const second: ids.Id = "fedcba9876543210fedcba9876543210".*;
    var first_lease = try Lease.create(&root, test_id);
    defer first_lease.deinit();
    try first_lease.save(&root, "first");
    var second_lease = try Lease.create(&root, second);
    defer second_lease.deinit();
    try second_lease.save(&root, "second");
    const dir = first_lease.directory_fd;
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("0123456789abcdef0123456789abcdef.session", dir, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.session"));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.session", 0o700));
    try std.testing.expectEqual(@as(c_int, 0), mkfifoat(dir, "cccccccccccccccccccccccccccccccc.session", 0o600));
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("missing", dir, "dddddddddddddddddddddddddddddddd.session"));
    const equal_times = [2]std.c.timespec{ .{ .sec = 100, .nsec = 0 }, .{ .sec = 100, .nsec = 0 } };
    try std.testing.expectEqual(@as(c_int, 0), std.c.utimensat(dir, test_id ++ ".session", &equal_times, 0));
    try std.testing.expectEqual(@as(c_int, 0), std.c.utimensat(dir, second ++ ".session", &equal_times, 0));
    const unreadable = fs.openAt(dir, test_id ++ ".session", .{ .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (unreadable < 0) return fs.osError();
    defer fs.closeFd(unreadable);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(unreadable, 0));
    const junk = fs.openAt(dir, "INVALID.session", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
    if (junk < 0) return fs.osError();
    fs.closeFd(junk);
    const result = try list(&root, a);
    defer a.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(i64, 100_000), result[0].modified_ms);
    try std.testing.expectEqual(result[0].modified_ms, result[1].modified_ms);
    try std.testing.expectEqualSlices(u8, &test_id, &result[0].id);
    try std.testing.expectEqualSlices(u8, &second, &result[1].id);
    const later_times = [2]std.c.timespec{ .{ .sec = 200, .nsec = 0 }, .{ .sec = 200, .nsec = 0 } };
    try std.testing.expectEqual(@as(c_int, 0), std.c.utimensat(dir, second ++ ".session", &later_times, 0));
    const later = try list(&root, a);
    defer a.free(later);
    try std.testing.expectEqual(@as(usize, 2), later.len);
    try std.testing.expectEqualSlices(u8, &second, &later[0].id);
    try std.testing.expectEqual(@as(i64, 200_000), later[0].modified_ms);
    try std.testing.expectEqualSlices(u8, &test_id, &later[1].id);
}
test "title sidecars are optional bounded and do not change checkpoint order" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const second: ids.Id = "fedcba9876543210fedcba9876543210".*;
    var first = try Lease.create(&root, test_id);
    defer first.deinit();
    try std.testing.expectError(error.ResumeNotFound, first.saveTitle(&root, session_metadata.Title.fromText("early")));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(root.io, ".thin/sessions/" ++ test_id ++ ".title", .{}));
    try first.save(&root, "one");
    var other = try Lease.create(&root, second);
    defer other.deinit();
    try other.save(&root, "two");
    const before = try list(&root, a);
    defer a.free(before);
    try std.testing.expectEqualStrings("", first.getTitle(&root).text());
    try first.saveTitle(&root, session_metadata.Title.fromText("中文标题"));
    var reader = try Lease.open(&root, test_id, false);
    defer reader.deinit();
    try std.testing.expectEqualStrings("中文标题", reader.getTitle(&root).text());
    try std.testing.expectError(error.ResumeReadOnly, reader.saveTitle(&root, session_metadata.Title.fromText("no")));
    try std.testing.expectEqualStrings("中文标题", first.getTitle(&root).text());
    const after = try list(&root, a);
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, &before[0].id, &after[0].id);
    try std.testing.expectEqualSlices(u8, &before[1].id, &after[1].id);
    try std.testing.expectEqual(before[0].modified_ms, after[0].modified_ms);
    for (after) |item| {
        try std.testing.expectEqualStrings(if (std.mem.eql(u8, &item.id, &test_id)) "中文标题" else "", item.title.text());
    }
    try tmp.dir.writeFile(root.io, .{ .sub_path = ".thin/sessions/" ++ test_id ++ ".title", .data = "\xff" });
    try std.testing.expectEqualStrings("", reader.getTitle(&root).text());
    const invalid = try list(&root, a);
    defer a.free(invalid);
    for (invalid) |item| try std.testing.expectEqualStrings("", item.title.text());
    try tmp.dir.deleteFile(root.io, ".thin/sessions/" ++ test_id ++ ".title");
    const missing = try list(&root, a);
    defer a.free(missing);
    for (missing) |item| try std.testing.expectEqualStrings("", item.title.text());
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("missing", first.directory_fd, test_id ++ ".title"));
    try std.testing.expectEqualStrings("", reader.getTitle(&root).text());
}
test "resume store atomic private writes concurrent read-only view and interrupted owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    try std.testing.expectError(error.ResumeNotFound, Lease.open(&root, test_id, false));
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    {
        var lease = try Lease.create(&root, test_id);
        defer lease.deinit();
        try std.testing.expectEqual(@as(u64, 0), (try fs.fileFromFd(lease.lock_fd).stat(root.io)).size);
        try lease.save(&root, "fake authenticated bytes\x00\xff");
        try std.testing.expectEqual(@as(u64, 0), (try fs.fileFromFd(lease.lock_fd).stat(root.io)).size);
        try std.testing.expectError(error.SessionInUse, Lease.open(&root, test_id, true));
        var view = try Lease.open(&root, test_id, false);
        defer view.deinit();
        const bytes = try view.load(&root);
        defer root.allocator.free(bytes);
        try std.testing.expectEqualStrings("fake authenticated bytes\x00\xff", bytes);
        try std.testing.expectError(error.ResumeReadOnly, view.save(&root, "never"));
    }
    {
        var lease = try Lease.open(&root, test_id, false);
        defer lease.deinit();
        const bytes = try lease.load(&root);
        defer root.allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, "fake authenticated bytes\x00\xff", bytes);
        try std.testing.expect(!lease.writable);
        try std.testing.expectError(error.ResumeReadOnly, lease.save(&root, "different"));
    }
    for ([_][]const u8{ ".session", ".resume-lock" }) |suffix| {
        const path = try std.fmt.allocPrint(root.allocator, ".thin/sessions/{s}{s}", .{ test_id, suffix });
        defer root.allocator.free(path);
        const stat = try tmp.dir.statFile(root.io, path, .{});
        try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    }
    {
        var lease = try Lease.open(&root, test_id, true);
        defer lease.deinit();
        try std.testing.expect(lease.writable);
        // Release ownership without a final save.
    }
    var recovered = try Lease.open(&root, test_id, true);
    defer recovered.deinit();
    const recovered_bytes = try recovered.load(&root);
    defer root.allocator.free(recovered_bytes);
    try std.testing.expectEqualStrings("fake authenticated bytes\x00\xff", recovered_bytes);
}
test "resume store detects changed snapshot and refuses unsafe paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var lease = try Lease.create(&root, test_id);
    defer lease.deinit();
    try lease.save(&root, "original");
    const path = ".thin/sessions/" ++ test_id ++ ".session";
    try tmp.dir.writeFile(root.io, .{ .sub_path = path, .data = "changed" });
    try std.testing.expectError(error.ResumeConflict, lease.save(&root, "next"));
    const changed = try lease.load(&root);
    defer root.allocator.free(changed);
    try std.testing.expectEqualStrings("changed", changed);
    try lease.save(&root, "next");
    try tmp.dir.deleteFile(root.io, path);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("missing", lease.directory_fd, test_id ++ ".session"));
    if (lease.load(&root)) |bytes| {
        root.allocator.free(bytes);
        return error.AcceptedSymlink;
    } else |_| {}
    try tmp.dir.deleteFile(root.io, path);
    if (mkfifoat(lease.directory_fd, test_id ++ ".session", 0o600) != 0) return error.FixtureFailed;
    try std.testing.expectError(error.UnsafeResumeFile, lease.load(&root));
}
test "resume store ignores arbitrary legacy markers and permission bits at load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    {
        var lease = try Lease.create(&root, test_id);
        defer lease.deinit();
        try lease.save(&root, "complete JSON-shaped history");
        try fs.fileFromFd(lease.lock_fd).writePositionalAll(root.io, "Aobsolete digest", 0);
        try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(lease.lock_fd, 0o644));
        const fd = fs.openAt(lease.directory_fd, test_id ++ ".session", .{ .NOFOLLOW = true, .CLOEXEC = true }, 0);
        if (fd < 0) return fs.osError();
        defer fs.closeFd(fd);
        try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(fd, 0o644));
    }
    var resumed = try Lease.open(&root, test_id, true);
    defer resumed.deinit();
    for ([_][]const u8{ "Aobsolete digest", "Cwrong digest", "arbitrary marker" }) |marker| {
        try fs.fileFromFd(resumed.lock_fd).writePositionalAll(root.io, marker, 0);
        const bytes = try resumed.load(&root);
        defer root.allocator.free(bytes);
        try std.testing.expectEqualStrings("complete JSON-shaped history", bytes);
    }
    try resumed.save(&root, "next complete history");
    const updated = try resumed.load(&root);
    defer root.allocator.free(updated);
    try std.testing.expectEqualStrings("next complete history", updated);
    const stat = try tmp.dir.statFile(root.io, ".thin/sessions/" ++ test_id ++ ".session", .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}
