//! Linux project-rooted text files. All traversal is relative to owned dirfds;
//! symlinks are rejected, including in the root path. No terminal interaction.
//! 中文：本模块只处理项目根目录内的 UTF-8 文本文件。所有访问都从已打开的目录 fd 出发，逐段 openat 解析路径，不依赖可被替换的绝对路径。

const std = @import("std");
const line_stats = @import("../util/line_stats.zig");

/// 文本读取结果：data 为截取后的内容（由 allocator 复制），total_bytes 为文件总字节数，truncated 表示之后仍有未返回的内容。
pub const ReadResult = struct { data: []const u8, total_bytes: u64, truncated: bool };

/// Linux x86_64 系统调用与 O_* 标志的本地声明（数值与 fcntl.h 一致）。
pub const linux = struct {
    /// 相对目录 fd 打开文件；dirfd 为 -100（AT_FDCWD）时相对当前目录。
    pub extern "c" fn openat(c_int, [*:0]const u8, c_int, c_uint) c_int;
    /// 对 fd 加咨询锁。
    pub extern "c" fn flock(c_int, c_int) c_int;

    /// O_DIRECTORY：要求目标必须是目录。
    pub const directory = 0x10000;
    /// O_NOFOLLOW：路径最后一段是符号链接时直接失败（ELOOP），防止越出根目录。
    pub const nofollow = 0x20000;
    /// O_CLOEXEC：exec 时自动关闭，避免 fd 泄漏给子进程。
    pub const cloexec = 0x80000;
    /// O_NONBLOCK：open 不因 FIFO 等特殊文件而阻塞。
    pub const nonblock = 0x800;
    /// O_CREAT：文件不存在时创建。
    pub const create = 0x40;
    /// O_EXCL：与 O_CREAT 同用，目标已存在则失败。
    pub const exclusive = 0x80;
};

/// 把刚刚失败的系统调用的 errno 映射为本模块的错误；必须在下一次 libc 调用前读取。
pub fn osError() anyerror {
    return switch (std.c._errno().*) {
        2 => error.FileNotFound,
        13, 1 => error.AccessDenied,
        17 => error.PathAlreadyExists,
        20 => error.NotDir,
        21 => error.IsDir,
        40 => error.SymlinkNotAllowed,
        36 => error.NameTooLong,
        28 => error.NoSpaceLeft,
        else => error.FileSystemError,
    };
}

/// 关闭 fd，忽略返回值：关闭失败通常无法补救，且 fd 仍应视为已释放。
pub fn closeFd(fd: c_int) void {
    _ = std.c.close(fd);
}

/// 相对 parent 打开子目录，带 O_DIRECTORY | O_NOFOLLOW，返回的新 fd 由调用方关闭。
pub fn openDirectory(parent: c_int, name: [*:0]const u8) !c_int {
    const fd = linux.openat(parent, name, linux.directory | linux.nofollow | linux.cloexec, 0);
    if (fd < 0) return osError();
    return fd;
}

/// 把原始 fd 包装成 std.Io.File，不接管所有权，关闭仍需调用 closeFd。
pub fn fileFromFd(fd: c_int) std.Io.File {
    // 与 openat 的 O_NONBLOCK 保持一致，读取 FIFO 等特殊文件时不会阻塞。
    return .{ .handle = fd, .flags = .{ .nonblocking = true } };
}

/// 校验文本：必须是合法 UTF-8，且不含 \n \r \t 以外的控制字符和 DEL(127)；否则视为二进制或非法文本。
pub fn validateText(bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    for (bytes) |c| if ((c < 32 and c != '\n' and c != '\r' and c != '\t') or c == 127)
        return error.BinaryFile;
}

/// 项目根目录：持有根目录 dirfd，之后的所有读写都相对该 fd 进行。
pub const Root = struct {
    /// 根目录的 dirfd，由 open 创建，deinit 时关闭。
    dir: std.Io.Dir,
    /// 根目录的规范绝对路径（realPath 结果），仅用于词法包含检查。
    path: []const u8,
    /// 用于 stat/读写等 I/O 操作的 std.Io 实例。
    io: std.Io,
    /// 持有 path 等堆内存的分配器。
    allocator: std.mem.Allocator,

    /// 打开 path 作为根目录。拒绝空路径、NUL、".."；路径中任何符号链接都会因 O_NOFOLLOW 失败。
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Root {
        if (path.len == 0 or std.mem.findScalar(u8, path, 0) != null) return error.InvalidPath;
        // -100 即 AT_FDCWD：绝对路径从 "/" 开始，相对路径从当前工作目录开始。
        var fd = try openDirectory(-100, if (std.fs.path.isAbsolute(path)) "/" else ".");
        errdefer closeFd(fd);
        var parts = std.mem.tokenizeScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
            if (std.mem.eql(u8, part, ".")) continue;
            const z = try allocator.dupeSentinel(u8, part, 0);
            defer allocator.free(z);
            const next = try openDirectory(fd, z);
            closeFd(fd);
            fd = next;
        }
        // 用最终 fd 反查规范路径，供之后 relative() 做词法包含检查。
        const dir: std.Io.Dir = .{ .handle = fd };
        var buffer: [4096]u8 = undefined;
        const n = try dir.realPath(io, &buffer);
        return .{ .dir = dir, .path = try allocator.dupe(u8, buffer[0..n]), .io = io, .allocator = allocator };
    }

    /// Independent open description anchored to this inode, not the stored path.
    /// Caller owns the result. Never retain a pointer to a movable Root value.
    pub fn duplicate(self: *const Root) !Root {
        const fd = try openDirectory(self.dir.handle, ".");
        errdefer closeFd(fd);
        return .{ .dir = .{ .handle = fd }, .path = try self.allocator.dupe(u8, self.path), .io = self.io, .allocator = self.allocator };
    }

    /// 关闭根 fd，释放 path，并把 self 置为 undefined 以防误用。
    pub fn deinit(self: *Root) void {
        closeFd(self.dir.handle);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Lexical containment check; actual operations still re-walk anchored fds.
    /// 中文：词法检查，拒绝 NUL 与 ".."，绝对路径必须位于根路径之下；真正的访问仍会从根 fd 逐级重走。
    pub fn relative(self: *Root, path: []const u8) ![]const u8 {
        if (path.len == 0 or std.mem.findScalar(u8, path, 0) != null) return error.InvalidPath;
        var rel = path;
        if (std.fs.path.isAbsolute(path)) {
            if (std.mem.eql(u8, self.path, "/")) {
                rel = path[1..];
            } else {
                // 前缀之后必须紧跟 '/'，防止 /root/thin2 被误判为位于 /root/thin 之下。
                if (!std.mem.startsWith(u8, path, self.path) or path.len <= self.path.len or path[self.path.len] != '/') return error.OutsideRoot;
                rel = path[self.path.len + 1 ..];
            }
        }
        var parts = std.mem.tokenizeScalar(u8, rel, '/');
        while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
        if (rel.len == 0 or rel[rel.len - 1] == '/') return error.InvalidPath;
        return rel;
    }

    /// 父目录 fd 加最后一段文件名：供 openat/renameat/unlinkat 等相对操作使用。
    pub const Parent = struct {
        /// 父目录的 dirfd，deinit 时关闭。
        fd: c_int,
        /// 最后一段文件名（以 0 结尾），由 allocator 持有。
        name: [:0]u8,
        /// 持有 name 的分配器。
        allocator: std.mem.Allocator,

        /// 关闭父目录 fd 并释放文件名。
        pub fn deinit(self: *Parent) void {
            closeFd(self.fd);
            self.allocator.free(self.name);
        }
    };

    /// 解析 path 的父目录，返回父目录 fd 与最后一段文件名；中间各段都用 O_NOFOLLOW 逐级打开。
    pub fn parent(self: *Root, path: []const u8) !Parent {
        const rel = try self.relative(path);
        // 用 "." 重新打开根目录得到独立 fd，之后逐段替换也不会关闭 self.dir。
        var fd = try openDirectory(self.dir.handle, ".");
        errdefer closeFd(fd);
        var parts = std.mem.tokenizeScalar(u8, rel, '/');
        var current = parts.next() orelse return error.InvalidPath;
        // 中间段逐级 openat 成子目录 fd；"." 段直接跳过。最后一段只是文件名，不在此打开。
        while (parts.next()) |next| {
            if (!std.mem.eql(u8, current, ".")) {
                const z = try self.allocator.dupeSentinel(u8, current, 0);
                defer self.allocator.free(z);
                const child = try openDirectory(fd, z);
                closeFd(fd);
                fd = child;
            }
            current = next;
        }
        // 最终文件名不能是 "."，否则无法指向一个普通文件。
        if (std.mem.eql(u8, current, ".")) return error.InvalidPath;
        return .{ .fd = fd, .name = try self.allocator.dupeSentinel(u8, current, 0), .allocator = self.allocator };
    }

    /// 从 offset 字节处读取最多 limit 字节的 UTF-8 文本，结果按完整字符截断，并校验文本合法性。
    pub fn read(self: *Root, allocator: std.mem.Allocator, path: []const u8, offset: u64, limit: usize) !ReadResult {
        var p = try self.parent(path);
        defer p.deinit();

        // NOFOLLOW 拒绝符号链接；NONBLOCK 保证 FIFO 等特殊文件不会让 open 挂起。
        const fd = linux.openat(p.fd, p.name, linux.nofollow | linux.cloexec | linux.nonblock, 0);
        if (fd < 0) return osError();
        defer closeFd(fd);
        const file = fileFromFd(fd);
        // 基于已打开的 fd 做 stat，而不是按路径重新查找，避免读取前后被替换（TOCTOU）。
        const stat = try file.stat(self.io);
        if (stat.kind != .file) return error.NotRegularFile;
        if (offset > stat.size or offset > std.math.maxInt(i64)) return error.InvalidOffset;

        // 多取 3 字节：UTF-8 一个字符最长 4 字节，因此可以完整解码 limit 处被切开的末尾字符。
        const count: usize = @intCast(@min(stat.size - offset, @as(u64, std.math.add(usize, limit, 3) catch return error.InvalidLimit)));
        const buffer = try allocator.alloc(u8, count);
        defer allocator.free(buffer);

        // 读到的字节数与 stat 不符，说明文件在读取过程中被修改。
        const n = try file.readPositionalAll(self.io, buffer, offset);
        if (n != count) return error.FileChanged;
        // Even a zero-byte request must not accept an offset into a continuation byte.
        if (n > 0) _ = std.unicode.utf8ByteSequenceLength(buffer[0]) catch return error.InvalidUtf8;

        // 逐个 UTF-8 字符校验并累加；超过 limit 的字符不返回。若第一个字符本身就超限，说明 limit 太小。
        var end: usize = 0;
        while (end < @min(limit, n)) {
            const width = std.unicode.utf8ByteSequenceLength(buffer[end]) catch return error.InvalidUtf8;
            if (width > n - end) return error.InvalidUtf8;
            try validateText(buffer[end..][0..width]);
            if (width > limit - end) {
                if (end == 0 and limit != 0) return error.ReadLimitTooSmall;
                break;
            }
            end += width;
        }

        // truncated 表示返回的结束位置仍未到文件末尾。
        return .{ .data = try allocator.dupe(u8, buffer[0..end]), .total_bytes = stat.size, .truncated = offset + end < stat.size };
    }
    /// 以默认权限原子写入文本文件；overwrite 为 false 时目标已存在则失败。
    pub fn write(self: *Root, path: []const u8, content: []const u8, overwrite: bool) !void {
        try self.writeMode(path, content, overwrite, null);
    }

    /// Explicit mode is used by Memory; ordinary writes retain rwx bits only.
    /// 中文：原子写入流程：先写同目录临时文件，再 rename 覆盖或 linkat 仅在不存在时创建，目标文件要么是旧内容要么是完整新内容。
    pub fn writeMode(self: *Root, path: []const u8, content: []const u8, overwrite: bool, forced_mode: ?u32) !void {
        try self.writeImpl(path, content, overwrite, forced_mode, null);
    }

    /// Optional line diff uses the SAME anchored old fd, before any mutation.
    /// This is a snapshot observation, not a lock/CAS against external writers.
    /// Stats allocation/read/complexity failure stays unknown, not write failure.
    pub fn writeObserved(self: *Root, path: []const u8, content: []const u8, overwrite: bool) !?line_stats.Changes {
        var changes: ?line_stats.Changes = null;
        try self.writeImpl(path, content, overwrite, null, &changes);
        return changes; // Value only: no fallible work after rename/link commit.
    }

    fn observeChanges(self: *Root, old: c_int, size: u64, content: []const u8) !?line_stats.Changes {
        if (size > line_stats.max_bytes or content.len > line_stats.max_bytes) return null;
        const before = self.allocator.alloc(u8, @intCast(size)) catch return null;
        defer self.allocator.free(before);
        const n = fileFromFd(old).readPositionalAll(self.io, before, 0) catch |err| {
            if (err == error.Canceled) return err;
            return null;
        };
        if (n != before.len) return null;
        validateText(before) catch return null;
        return line_stats.compare(self.allocator, before, content) catch null;
    }

    fn writeImpl(self: *Root, path: []const u8, content: []const u8, overwrite: bool, forced_mode: ?u32, observed: ?*?line_stats.Changes) !void {
        // 先校验文本，避免写入临时文件后才发现内容非法。
        try validateText(content);
        var p = try self.parent(path);
        defer p.deinit();

        // 默认权限 0600；覆盖已有文件时沿用其权限位，除非调用方显式指定 forced_mode（例如 Memory）。
        var mode: u32 = forced_mode orelse 0o600;
        // 检查目标是否已存在：存在且不允许覆盖则报错；errno 为 ENOENT(2) 时目标不存在，可以继续创建。
        const old = linux.openat(p.fd, p.name, linux.nofollow | linux.cloexec | linux.nonblock, 0);
        if (old >= 0) {
            defer closeFd(old);
            if (!overwrite) return error.PathAlreadyExists;
            const stat = try fileFromFd(old).stat(self.io);
            if (stat.kind != .file) return error.NotRegularFile;
            if (forced_mode == null) mode = stat.permissions.toMode() & 0o777;
            if (observed) |out| out.* = try self.observeChanges(old, stat.size, content);
        } else if (std.c._errno().* != 2) return osError() else if (observed) |out| {
            out.* = .{ .added = line_stats.count(content) };
        }

        // 临时文件名形如 .thin-tmp-<32 位十六进制随机数>，80 字节缓冲区足够容纳。
        var name_buffer: [80]u8 = undefined;
        var temp_fd: c_int = -1;
        var name: [:0]u8 = undefined;
        // 临时文件与目标位于同一目录，保证之后的 rename/linkat 不跨文件系统。最多尝试 128 次，仅 EEXIST(17) 时重试。
        for (0..128) |_| {
            var random: [16]u8 = undefined;
            try self.io.randomSecure(&random);
            const hex = std.fmt.bytesToHex(random, .lower);
            name = try std.fmt.bufPrintSentinel(&name_buffer, ".thin-tmp-{s}", .{hex}, 0);
            temp_fd = linux.openat(p.fd, name, 1 | linux.create | linux.exclusive | linux.nofollow | linux.cloexec, 0o600);
            if (temp_fd >= 0) break;
            if (std.c._errno().* != 17) return osError();
        }
        if (temp_fd < 0) return error.TempNameExhausted;

        // defer 为后进先出：先 unlink 临时名，再关闭 fd。rename 成功后临时名已不存在，unlink 失败被忽略。
        defer closeFd(temp_fd);
        defer _ = std.c.unlinkat(p.fd, name, 0);

        try fileFromFd(temp_fd).writePositionalAll(self.io, content, 0);

        // 临时文件以 0600 创建，内容写完后才设为目标权限，避免写入期间权限过宽。
        if (std.c.fchmod(temp_fd, mode) != 0) return osError();

        // rename 原子替换目标：读者要么看到旧文件，要么看到新文件。
        if (overwrite) {
            if (std.c.renameat(p.fd, name, p.fd, p.name) != 0) return osError();
        } else {
            // Atomic create-if-absent. Never stat-then-rename without NOREPLACE.
            // 中文：linkat 在目标已存在时返回 EEXIST，因此不存在先检查后创建的竞争窗口。
            if (std.c.linkat(p.fd, name, p.fd, p.name, 0) != 0) return osError();
        }
    }
};

/// 测试辅助：取得 TmpDir 的规范路径，并以它打开 Root。
fn testRoot(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Root {
    var buffer: [4096]u8 = undefined;
    const n = try dir.realPath(io, &buffer);
    return Root.open(a, io, buffer[0..n]);
}

// 测试：读写、范围读取、UTF-8 边界、覆盖失败与权限保留。
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
    try std.testing.expectError(error.InvalidUtf8, root.read(a, "a", 2, 4));
    try std.testing.expectError(error.InvalidUtf8, root.read(a, "a", 2, 0));
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

/// libc 的 mkfifoat，测试用它在根目录下创建 FIFO，验证非普通文件会被拒绝且不阻塞。
extern "c" fn mkfifoat(c_int, [*:0]const u8, c_uint) c_int;

// 测试：拒绝路径穿越、符号链接、目录与 FIFO，且不会阻塞。
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
