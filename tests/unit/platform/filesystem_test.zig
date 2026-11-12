test "guarded read keeps checked fd" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    var root = try Root.open(a, io, buffer[0..try tmp.dir.realPath(io, &buffer)]);
    defer root.deinit();
    try root.write("payload.txt", "checked original", false);
    const Guard = struct {
        root: *Root,
        checked_open: bool = false,
        fn check(raw: *anyopaque, _: Root.Parent, fd: ?c_int) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (fd == null) return;
            self.checked_open = true;
            // A deterministic namespace race exactly after the final check.
            try self.root.write("payload.txt", "unchecked replacement", true);
        }
    };
    var guard: Guard = .{ .root = &root };
    const result = try root.readExternalGuarded(a, "payload.txt", 0, 100, .{ .context = &guard, .check_fn = Guard.check });
    defer a.free(result.data);
    try std.testing.expect(guard.checked_open);
    try std.testing.expectEqualStrings("checked original", result.data);
    const replacement = try root.read(a, "payload.txt", 0, 100);
    defer a.free(replacement.data);
    try std.testing.expectEqualStrings("unchecked replacement", replacement.data);
}
test "guarded read checks post-open identity" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    var root = try Root.open(a, io, buffer[0..try tmp.dir.realPath(io, &buffer)]);
    defer root.deinit();
    try root.write("payload.txt", "public", false);
    try root.write("private.txt", "synthetic private", false);
    const Guard = struct {
        root: *Root,
        checks: usize = 0,
        fn check(raw: *anyopaque, parent_: Root.Parent, fd: ?c_int) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.checks += 1;
            if (fd) |opened| {
                if (try sameObjectAt(opened, self.root.dir.handle, "private.txt")) return error.GuardDenied;
            } else {
                // Substitute the leaf between the parent check and openat.
                if (std.c.unlinkat(parent_.fd, parent_.name, 0) != 0) return osError();
                if (std.c.linkat(self.root.dir.handle, "private.txt", parent_.fd, parent_.name, 0) != 0) return osError();
            }
        }
    };
    var guard: Guard = .{ .root = &root };
    try std.testing.expectError(error.GuardDenied, root.readExternalGuarded(a, "payload.txt", 0, 100, .{ .context = &guard, .check_fn = Guard.check }));
    try std.testing.expectEqual(@as(usize, 2), guard.checks);
}
test "root reads writes ranges text and failed overwrite" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    try root.write("a", "a中文z", false);
    try std.testing.expectError(error.PathAlreadyExists, root.write("a", "lost", false));
    try std.testing.expectError(error.InvalidUtf8, root.write("a", "\xff", true));
    const r = try root.read(a, "a", 1, 4);
    defer a.free(r.data);
    try std.testing.expectEqualStrings("中", r.data);
    try std.testing.expect(r.truncated);
    try std.testing.expectEqual(@as(u64, 8), r.total_bytes);
    try std.testing.expectError(error.ReadLimitTooSmall, root.read(a, "a", 1, 1));
    const aligned = try root.read(a, "a", 2, 4);
    defer a.free(aligned.data);
    try std.testing.expectEqualStrings("中", aligned.data);
    try std.testing.expectEqual(@as(u64, 1), aligned.offset);
    const aligned_zero = try root.read(a, "a", 2, 0);
    defer a.free(aligned_zero.data);
    try std.testing.expectEqual(@as(usize, 0), aligned_zero.data.len);
    try std.testing.expectEqual(@as(u64, 1), aligned_zero.offset);
    try std.testing.expect(aligned_zero.truncated);
    const zero = try root.read(a, "a", 0, 0);
    defer a.free(zero.data);
    try std.testing.expectEqual(@as(usize, 0), zero.data.len);
    try std.testing.expect(zero.truncated);
    try std.testing.expectError(error.InvalidOffset, root.read(a, "a", 9, 1));
    const eof = try root.read(a, "a", 8, 8);
    defer a.free(eof.data);
    try std.testing.expectEqual(@as(usize, 0), eof.data.len);
    try std.testing.expect(!eof.truncated);

    var permissions_parent = try root.parent("a");
    defer permissions_parent.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmodat(permissions_parent.fd, permissions_parent.name, 0o640, 0));

    // 覆盖写入应保留原有的 0640 权限位。
    try root.write("a", "new", true);
    const mode = try root.dir.statFile(io, "a", .{});
    try std.testing.expectEqual(@as(u32, 0o640), mode.permissions.toMode() & 0o777);
    const abs = try std.fs.path.join(a, &.{ root.path, "a" });
    defer a.free(abs);
    const full = try root.read(a, abs, 0, 100);
    defer a.free(full.data);
    try std.testing.expectEqualStrings("new", full.data);

    try tmp.dir.writeFile(io, .{ .sub_path = "binary", .data = "a\x00b" });
    try tmp.dir.writeFile(io, .{ .sub_path = "invalid", .data = "\xff" });
    try std.testing.expectError(error.BinaryFile, root.read(a, "binary", 0, 100));
    try std.testing.expectError(error.InvalidUtf8, root.read(a, "invalid", 0, 100));
}
test "image binary snapshots detect short reads growth and metadata mutation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, std.testing.io, tmp.dir);
    defer root.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = "abc" });
    const Fault = struct {
        var mode: enum { short, growth, metadata } = .short;
        var calls: usize = 0;
        fn stat(raw: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
            var result = try std.testing.io.vtable.fileStat(raw, file);
            calls += 1;
            if (calls == 1) switch (mode) {
                .short => result.size += 1,
                .growth => result.size -= 1,
                .metadata => {},
            };
            if (calls == 2 and mode == .metadata) result.nlink += 1;
            return result;
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.fileStat = Fault.stat;
    root.io.vtable = &vtable;
    for ([_]@TypeOf(Fault.mode){ .short, .growth, .metadata }) |mode| {
        Fault.mode = mode;
        Fault.calls = 0;
        try std.testing.expectError(error.FileChanged, root.readBinary(a, "file", 10));
    }
}
test "image binary snapshots are complete bounded anchored and reject special files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "binary", .data = "\xff\x00\x01" });
    const bytes = try root.readBinary(a, "binary", 3);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("\xff\x00\x01", bytes);
    try std.testing.expectError(error.FileTooLarge, root.readBinary(a, "binary", 2));
    try std.testing.expectError(error.InvalidPath, root.readBinary(a, "../binary", 10));
    try tmp.dir.symLink(io, "binary", "link", .{});
    try std.testing.expectError(error.SymlinkNotAllowed, root.readBinary(a, "link", 10));
    try tmp.dir.createDir(io, "dir", .default_dir);
    try std.testing.expectError(error.NotRegularFile, root.readBinary(a, "dir", 10));
    try tmp.dir.symLink(io, "dir", "dirlink", .{});
    try std.testing.expectError(error.NotDir, root.readBinary(a, "dirlink/x", 10));
    var parent_ = try root.parent("pipe");
    defer parent_.deinit();
    const C = struct {
        extern "c" fn mkfifoat(c_int, [*:0]const u8, c_uint) c_int;
    };
    try std.testing.expectEqual(@as(c_int, 0), C.mkfifoat(parent_.fd, parent_.name, 0o600));
    try std.testing.expectError(error.NotRegularFile, root.readBinary(a, "pipe", 10));
}
test "root UTF8 ranges align every character byte and paginate without loss" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    const text = "aé中😀z";
    try root.write("text", text, false);
    const boundaries = [_]usize{ 0, 1, 3, 6, 10, 11 };
    for (boundaries[0 .. boundaries.len - 1], boundaries[1..]) |first, next| {
        for (first..next) |offset| {
            const result = try root.read(a, "text", offset, 64);
            defer a.free(result.data);
            try std.testing.expectEqual(first, result.offset);
            try std.testing.expectEqualStrings(text[first..], result.data);
            try std.testing.expect(!result.truncated);
        }
    }
    var offset: u64 = 0;
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(a);
    for (boundaries[2..]) |next| {
        const page = try root.read(a, "text", offset, 4);
        defer a.free(page.data);
        try std.testing.expectEqual(offset, page.offset);
        try std.testing.expect(page.data.len > 0 and page.data.len <= 4);
        offset = page.offset + page.data.len;
        try std.testing.expectEqual(next, offset);
        try std.testing.expectEqual(offset < text.len, page.truncated);
        try collected.appendSlice(a, page.data);
    }
    try std.testing.expectEqualStrings(text, collected.items);
    const eof = try root.read(a, "text", text.len, 4);
    defer a.free(eof.data);
    try std.testing.expectEqual(@as(u64, text.len), eof.offset);
    try std.testing.expectEqual(@as(usize, 0), eof.data.len);
    try std.testing.expect(!eof.truncated);
    try std.testing.expectError(error.InvalidOffset, root.read(a, "text", std.math.maxInt(u64), 4));
    const large_page = try root.read(a, "text", 1, std.math.maxInt(usize));
    defer a.free(large_page.data);
    try std.testing.expectEqual(@as(u64, 1), large_page.offset);
    try std.testing.expectEqual(@as(u64, text.len), large_page.total_bytes);
    try std.testing.expectEqualStrings(text[1..], large_page.data);
    try std.testing.expect(!large_page.truncated);
    const zero_page = try root.read(a, "text", 1, 0);
    defer a.free(zero_page.data);
    try std.testing.expectEqual(@as(usize, 0), zero_page.data.len);
    try std.testing.expect(zero_page.truncated);
    for (7..10) |inside| try std.testing.expectError(error.ReadLimitTooSmall, root.read(a, "text", inside, 3));

    // Same byte parameters as the reported failure, without reading any session.
    var source: [240]u8 = @splat('b');
    @memset(source[0..37], 'a');
    @memcpy(source[37..40], "中");
    try root.write("source", &source, false);
    const range = try root.read(a, "source", 39, 120);
    defer a.free(range.data);
    try std.testing.expectEqual(@as(u64, 37), range.offset);
    try std.testing.expectEqualStrings(source[37..157], range.data);
    try std.testing.expect(range.truncated);
}
test "root UTF8 alignment never repairs malformed text or admits binary bytes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    for ([_][]const u8{ "a\x80z", "\x80\x80\x80\x80z", "\xc0\xafz", "\xed\xa0\x80z", "\xf4\x90\x80\x80z", "\xe4\xb8", "\xf0\x9f\x98" }) |invalid| {
        try tmp.dir.writeFile(io, .{ .sub_path = "invalid", .data = invalid });
        for ([_]usize{ 0, 4, 64 }) |limit| {
            try std.testing.expectError(error.InvalidUtf8, root.read(a, "invalid", 1, limit));
        }
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "binary", .data = "中\x00" });
    try std.testing.expectError(error.BinaryFile, root.read(a, "binary", 1, 64));
}
test "root duplicate retains replaced inode and independent ownership" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "project", 0o700));
    var parent_root = try testRoot(a, io, tmp.dir);
    defer parent_root.deinit();
    const project = try std.fs.path.join(a, &.{ parent_root.path, "project" });
    defer a.free(project);
    var root = try Root.open(a, io, project);
    try root.write("original", "old", false);
    try std.testing.expectEqual(@as(c_int, 0), std.c.renameat(tmp.dir.handle, "project", tmp.dir.handle, "retired"));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "project", 0o700));
    var copy = try root.duplicate();
    defer copy.deinit();
    try std.testing.expectEqualStrings(root.path, copy.path);
    try std.testing.expect(root.path.ptr != copy.path.ptr);
    try std.testing.expect(root.dir.handle != copy.dir.handle);
    root.deinit();
    const result = try copy.read(a, "original", 0, 100);
    defer a.free(result.data);
    try std.testing.expectEqualStrings("old", result.data);
    try copy.write("new", "anchored", false);
    try std.testing.expectError(error.FileNotFound, parent_root.read(a, "project/new", 0, 100));
    const anchored = try parent_root.read(a, "retired/new", 0, 100);
    defer a.free(anchored.data);
    try std.testing.expectEqualStrings("anchored", anchored.data);
}
test "root rejects traversal symlinks directories and FIFO without blocking" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, backend.io(), tmp.dir);
    defer root.deinit();
    try std.testing.expectError(error.InvalidPath, root.read(a, "../secret", 0, 1));
    try std.testing.expectError(error.InvalidPath, root.write("x/../y", "", false));
    try std.testing.expectError(error.InvalidPath, root.write("x\x00y", "", false));
    try std.testing.expectError(error.OutsideRoot, root.read(a, "/etc/not-read", 0, 1));

    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(root.dir.handle, "sub", 0o700));
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("/", root.dir.handle, "escape"));
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("sub", root.dir.handle, "link"));
    try std.testing.expectError(error.NotDir, root.read(a, "escape/etc/not-read", 0, 1));

    // 指向目录的符号链接同样被 O_NOFOLLOW 拒绝。
    try std.testing.expectError(error.SymlinkNotAllowed, root.write("link", "", true));
    try std.testing.expectError(error.NotRegularFile, root.read(a, "sub", 0, 1));

    try std.testing.expectEqual(@as(c_int, 0), mkfifoat(root.dir.handle, "fifo", 0o600));
    try std.testing.expectError(error.NotRegularFile, root.read(a, "fifo", 0, 1));
    try std.testing.expectError(error.NotRegularFile, root.write("fifo", "x", true));
    try std.testing.expectError(error.FileNotFound, root.write("missing/child", "x", false));
}
