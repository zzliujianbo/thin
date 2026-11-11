test "Darwin Root accepts verified system aliases without following user links" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    for ([_][]const u8{ "/tmp", "/var" }) |alias| {
        var root = try fs.Root.open(t.allocator, t.io, alias);
        defer root.deinit();
        try t.expect(std.mem.startsWith(u8, root.path, "/private/"));
    }
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "real", .default_dir);
    try t.expectEqual(@as(c_int, 0), std.c.symlinkat("real", tmp.dir.handle, "user-link"));
    var buffer: [4096]u8 = undefined;
    const base = buffer[0..try tmp.dir.realPath(t.io, &buffer)];
    const linked = try std.fs.path.join(t.allocator, &.{ base, "user-link" });
    defer t.allocator.free(linked);
    try t.expectError(error.NotDir, fs.Root.open(t.allocator, t.io, linked));
}
test "filesystem target flags retain nonblocking cloexec and exclusive creation" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const fd = fs.openAt(tmp.dir.handle, "file", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0o600);
    if (fd < 0) return fs.osError();
    defer fs.closeFd(fd);
    const descriptor_flags = std.c.fcntl(fd, std.c.F.GETFD);
    try t.expect(descriptor_flags >= 0 and descriptor_flags & std.posix.FD_CLOEXEC != 0);
    const nonblock: u32 = @bitCast(std.c.O{ .NONBLOCK = true });
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    try t.expect(flags >= 0 and flags & @as(c_int, @intCast(nonblock)) != 0);
    try t.expectEqual(@as(c_int, -1), fs.openAt(tmp.dir.handle, "file", .{ .CREAT = true, .EXCL = true }, 0o600));
    try t.expectEqual(std.c.E.EXIST, fs.errno());
    try t.expectEqual(@as(u32, 0o600), (try fs.fileFromFd(fd).stat(t.io)).permissions.toMode() & 0o777);
}
test "filesystem protected identity handles unreadable files and hardlink aliases" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    try root.write("private", "synthetic private data", false);
    try root.write("other", "public", false);
    const fd = try openFile(root.dir.handle, "private");
    defer fs.closeFd(fd);
    try t.expectEqual(@as(c_int, 0), std.c.linkat(root.dir.handle, "private", root.dir.handle, "alias", 0));
    try t.expectEqual(@as(c_int, 0), std.c.fchmod(fd, 0));
    defer _ = std.c.fchmod(fd, 0o600);
    if (std.c.geteuid() != 0) {
        try t.expectEqual(@as(c_int, -1), fs.openAt(root.dir.handle, "private", .{ .NOFOLLOW = true }, 0));
        try t.expectEqual(error.AccessDenied, fs.osError());
    }
    // The candidate fd pins its inode, so a metadata-only protected-name lookup
    // needs no second leaf fd to prevent a false equality through inode reuse.
    try t.expect(try fs.sameObjectAt(fd, root.dir.handle, "private"));
    try t.expect(try fs.sameObjectAt(fd, root.dir.handle, "alias"));
    try t.expect(!try fs.sameObjectAt(fd, root.dir.handle, "other"));
    try t.expectError(error.FileNotFound, fs.sameObjectAt(fd, root.dir.handle, "missing"));
}
test "filesystem metadata checks never follow symlinks or open FIFO and device leaves" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    try root.write("private", "synthetic", false);
    const fd = try openFile(root.dir.handle, "private");
    defer fs.closeFd(fd);
    try t.expectEqual(@as(c_int, 0), std.c.symlinkat("private", root.dir.handle, "link"));
    try t.expectEqual(@as(c_int, 0), std.c.symlinkat("missing", root.dir.handle, "dangling"));
    const C = struct {
        extern "c" fn mkfifoat(c_int, [*:0]const u8, c_uint) c_int;
    };
    try t.expectEqual(@as(c_int, 0), C.mkfifoat(root.dir.handle, "fifo", 0o600));
    for ([_][*:0]const u8{ "link", "dangling", "fifo" }) |name|
        try t.expect(!try fs.sameObjectAt(fd, root.dir.handle, name));
    const devices = try fs.openDirectory(std.c.AT.FDCWD, "/dev");
    defer fs.closeFd(devices);
    try t.expect(!try fs.sameObjectAt(fd, devices, "null"));
    for ([_][*:0]const u8{ "", ".", "..", "../private", "sub/private", "/private" }) |name|
        try t.expectError(error.InvalidPath, fs.sameObjectAt(fd, root.dir.handle, name));
}
test "filesystem protected lookup is fresh and parent identity stays fd anchored" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try t.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "project", 0o700));
    const project = try fs.openDirectory(tmp.dir.handle, "project");
    defer fs.closeFd(project);
    const fd = fs.openAt(project, "private", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
    if (fd < 0) return fs.osError();
    defer fs.closeFd(fd);
    try t.expect(try fs.sameObjectAt(fd, project, "private"));
    try t.expectEqual(@as(c_int, 0), std.c.renameat(tmp.dir.handle, "project", tmp.dir.handle, "retired"));
    try t.expectEqual(@as(c_int, 0), std.c.mkdirat(tmp.dir.handle, "project", 0o700));
    const replacement = try fs.openDirectory(tmp.dir.handle, "project");
    defer fs.closeFd(replacement);
    try t.expect(!try fs.sameObject(project, replacement));
    try t.expect(try fs.sameObjectAt(fd, project, "private"));
    try t.expectError(error.FileNotFound, fs.sameObjectAt(fd, replacement, "private"));
    try t.expectEqual(@as(c_int, 0), std.c.renameat(project, "private", project, "previous"));
    const next = fs.openAt(project, "private", .{ .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
    if (next < 0) return fs.osError();
    defer fs.closeFd(next);
    try t.expect(!try fs.sameObjectAt(fd, project, "private"));
    try t.expect(try fs.sameObjectAt(fd, project, "previous"));
}
test "filesystem portable AGENTS and linked skill discovery preserve nofollow policies" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root = try rootFor(tmp.dir);
    defer root.deinit();
    for ([_][*:0]const u8{ "home", "home/.thin", "home/.agents", "home/.agents/skills", "home/skill-source", "project", "project/.git", "project/sub" }) |name|
        try t.expectEqual(@as(c_int, 0), std.c.mkdirat(root.dir.handle, name, 0o700));
    try root.write("home/.thin/AGENTS.md", "global instructions", false);
    try root.write("project/AGENTS.md", "project instructions", false);
    try root.write("home/skill-source/SKILL.md", "---\nname: portable\ndescription: metadata only\n---\nPRIVATE_SKILL_BODY\n", false);
    try t.expectEqual(@as(c_int, 0), std.c.symlinkat("../../skill-source", root.dir.handle, "home/.agents/skills/linked"));
    const home = try std.fs.path.join(a, &.{ root.path, "home" });
    const cwd = try std.fs.path.join(a, &.{ root.path, "project/sub" });
    const first = try context.load(a, t.io, home, cwd, "/bin/bash");
    try t.expect(std.mem.indexOf(u8, first.agents_text, "global instructions") != null);
    try t.expect(std.mem.indexOf(u8, first.agents_text, "project instructions") != null);
    try t.expect(std.mem.indexOf(u8, first.agents, "\"name\":\"portable\"") != null);
    try t.expect(std.mem.indexOf(u8, first.agents, "PRIVATE_SKILL_BODY") == null);
    try t.expectEqual(@import("builtin").os.tag, first.os);
    // A present but invalid override suppresses the base, without treating the
    // platform's ELOOP number as an unknown I/O error or following the link.
    try t.expectEqual(@as(c_int, 0), std.c.symlinkat("AGENTS.md", root.dir.handle, "project/AGENTS.override.md"));
    try root.write("home/skill-source/actual.md", "---\nname: forbidden\ndescription: linked document\n---\n", false);
    try t.expectEqual(@as(c_int, 0), std.c.unlinkat(root.dir.handle, "home/skill-source/SKILL.md", 0));
    try t.expectEqual(@as(c_int, 0), std.c.symlinkat("actual.md", root.dir.handle, "home/skill-source/SKILL.md"));
    const second = try context.load(a, t.io, home, cwd, "/bin/bash");
    try t.expect(std.mem.indexOf(u8, second.agents_text, "global instructions") != null);
    try t.expect(std.mem.indexOf(u8, second.agents_text, "project instructions") == null);
    try t.expect(std.mem.indexOf(u8, second.agents, "\"name\":\"forbidden\"") == null);
}
