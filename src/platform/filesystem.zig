//! POSIX dirfd-anchored files (Linux and macOS). Normal operations stay project-rooted; the
//! explicit readExternal text path also permits absolute/parent paths.
//! Symlinks remain rejected. No terminal interaction.

const std = @import("std");
const line_stats = @import("../util/line_stats.zig");
const native = @import("filesystem_native.zig");

/// 文本读取结果：data 为独立复制的内容，offset 为字符对齐后的真实字节起点。
/// total_bytes 为文件总字节数，truncated 表示之后仍有未返回的内容。
pub const ReadResult = struct { data: []const u8, offset: u64, total_bytes: u64, truncated: bool };

/// Narrow target-aware libc boundary; callers keep their own failure policies.
pub const openAt = native.openAt;
pub const flock = native.flock;
pub const LOCK = native.LOCK;
pub const errno = native.errno;
pub const osError = native.osError;

/// 关闭 fd，忽略返回值：关闭失败通常无法补救，且 fd 仍应视为已释放。
pub fn closeFd(fd: c_int) void {
    _ = std.c.close(fd);
}

/// 相对 parent 打开子目录，带 O_DIRECTORY | O_NOFOLLOW，返回的新 fd 由调用方关闭。
pub fn openDirectory(parent: c_int, name: [*:0]const u8) !c_int {
    const fd = openAt(parent, name, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (fd < 0) return if (errno() == .LOOP) error.NotDir else osError();
    return fd;
}

/// 把原始 fd 包装成 std.Io.File，不接管所有权，关闭仍需调用 closeFd。
pub fn fileFromFd(fd: c_int) std.Io.File {
    // 与 openat 的 O_NONBLOCK 保持一致，读取 FIFO 等特殊文件时不会阻塞。
    return .{ .handle = fd, .flags = .{ .nonblocking = true } };
}

/// Descriptor identity includes the device: inode numbers alone are not global.
pub fn sameObject(left: c_int, right: c_int) !bool {
    return (try native.identity(left)).eql(try native.identity(right));
}

/// Compare an already-open object with the current protected directory entry.
/// fd stays open throughout: its inode cannot be reused during the comparison.
/// Query the protected leaf without opening it, even if unreadable/FIFO/device.
/// This is a fresh namespace snapshot, not a lock over later name changes.
pub fn sameObjectAt(fd: c_int, parent: c_int, name: [*:0]const u8) !bool {
    const leaf = std.mem.span(name);
    if (leaf.len == 0 or std.mem.indexOfScalar(u8, leaf, '/') != null or
        std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return error.InvalidPath;
    return (try native.identity(fd)).eql(try native.identityAt(parent, name));
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

    /// 打开 path 作为根目录。拒绝空路径、NUL、".."；仅 Darwin 已验证的根用户系统别名
    /// /tmp、/var 可重写，其余路径中的符号链接仍因 O_NOFOLLOW 失败。
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Root {
        if (path.len == 0 or std.mem.findScalar(u8, path, 0) != null) return error.InvalidPath;
        // Only Apple's verified root-owned system aliases are rewritten;
        // arbitrary HOME/project symlinks still fail the anchored nofollow walk.
        const canonical = if (@import("builtin").os.tag == .macos and std.fs.path.isAbsolute(path))
            try native.systemPath(allocator, path)
        else
            null;
        defer if (canonical) |owned| allocator.free(owned);
        const walk_path = canonical orelse path;
        // AT_FDCWD is target-dependent (-100 on Linux, -2 on Darwin).
        var fd = try openDirectory(std.c.AT.FDCWD, if (std.fs.path.isAbsolute(walk_path)) "/" else ".");
        errdefer closeFd(fd);
        var parts = std.mem.tokenizeScalar(u8, walk_path, '/');
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
        return self.walkParent(try openDirectory(self.dir.handle, "."), rel);
    }

    /// Read-only traversal may leave the project, but still follows no symlinks.
    /// In-project absolute paths retain the original project inode anchor.
    pub fn readParent(self: *Root, path: []const u8) !Parent {
        if (path.len == 0 or path.len > 4096 or std.mem.findScalar(u8, path, 0) != null or path[path.len - 1] == '/') return error.InvalidPath;
        if (std.fs.path.isAbsolute(path)) {
            if (self.projectReadSuffix(path)) |rel|
                return self.walkParent(try openDirectory(self.dir.handle, "."), rel);
            return self.walkParent(try openDirectory(std.c.AT.FDCWD, "/"), path[1..]);
        }
        return self.walkParent(try openDirectory(self.dir.handle, "."), path);
    }

    /// Ignore only separators and dots in the launch-path prefix. Never cancel
    /// '..': link/../file must still visit link and fail NOFOLLOW.
    fn projectReadSuffix(self: *const Root, path: []const u8) ?[]const u8 {
        var root_parts = std.mem.tokenizeScalar(u8, self.path, '/');
        var parts = std.mem.tokenizeScalar(u8, path, '/');
        while (root_parts.next()) |wanted| {
            var part = parts.next() orelse return null;
            while (std.mem.eql(u8, part, ".")) part = parts.next() orelse return null;
            if (!std.mem.eql(u8, wanted, part)) return null;
        }
        return parts.rest(); // Preserve every remaining component for openat.
    }

    /// Policy belongs to the caller. The second check receives the exact open
    /// file subsequently read, not a path which will be traversed again.
    pub const ReadGuard = struct {
        context: *anyopaque,
        check_fn: *const fn (*anyopaque, Parent, ?c_int) anyerror!void,

        fn check(self: ReadGuard, parent_: Parent, fd: ?c_int) !void {
            try self.check_fn(self.context, parent_, fd);
        }
    };

    /// Consumes an independent directory fd, closing it on every failure.
    fn walkParent(self: *Root, owned_fd: c_int, rel: []const u8) !Parent {
        var fd = owned_fd;
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
        if (std.mem.eql(u8, current, ".") or std.mem.eql(u8, current, "..")) return error.InvalidPath;
        return .{ .fd = fd, .name = try self.allocator.dupeSentinel(u8, current, 0), .allocator = self.allocator };
    }

    /// Complete bounded binary snapshot from one anchored regular-file fd.
    /// Never truncates; metadata checks detect ordinary concurrent mutation (not a lock).
    pub fn readBinary(self: *Root, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
        return self.readBinaryGuarded(allocator, path, limit, null);
    }

    pub fn readBinaryGuarded(self: *Root, allocator: std.mem.Allocator, path: []const u8, limit: ?usize, guard: ?ReadGuard) ![]u8 {
        var parent_ = try self.parent(path);
        defer parent_.deinit();
        if (guard) |policy| try policy.check(parent_, null);
        const fd = openAt(parent_.fd, parent_.name, .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
        if (fd < 0) return osError();
        defer closeFd(fd);
        if (guard) |policy| try policy.check(parent_, fd);
        const file = fileFromFd(fd);
        const before = try file.stat(self.io);
        if (before.kind != .file) return error.NotRegularFile;
        if (limit) |bound| if (before.size > bound) return error.FileTooLarge;
        const data = try allocator.alloc(u8, @intCast(before.size));
        errdefer allocator.free(data);
        if (try file.readPositionalAll(self.io, data, 0) != data.len) return error.FileChanged;
        var extra: [1]u8 = undefined;
        if (try file.readPositionalAll(self.io, &extra, before.size) != 0) return error.FileChanged;
        const after = try file.stat(self.io);
        if (before.size != after.size or before.inode != after.inode or before.kind != after.kind or
            before.nlink != after.nlink or !std.meta.eql(before.permissions, after.permissions) or
            !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime)) return error.FileChanged;
        return data;
    }

    /// 从 offset 附近读取最多 limit 字节的 UTF-8 文本。字符内部的起点最多向前
    /// 对齐 3 字节，返回真实 offset；末尾按完整字符截断，非法文本仍然拒绝。
    pub fn read(self: *Root, allocator: std.mem.Allocator, path: []const u8, offset: u64, limit: usize) !ReadResult {
        var p = try self.parent(path);
        defer p.deinit();
        return self.readParentText(allocator, p, offset, limit, null);
    }

    /// Explicit text-tool read, not a policy change for Memory, images or writes.
    pub fn readExternal(self: *Root, allocator: std.mem.Allocator, path: []const u8, offset: u64, limit: usize) !ReadResult {
        return self.readExternalGuarded(allocator, path, offset, limit, null);
    }

    pub fn readExternalGuarded(self: *Root, allocator: std.mem.Allocator, path: []const u8, offset: u64, limit: usize, guard: ?ReadGuard) !ReadResult {
        var p = try self.readParent(path);
        defer p.deinit();
        return self.readParentText(allocator, p, offset, limit, guard);
    }

    fn readParentText(self: *Root, allocator: std.mem.Allocator, p: Parent, offset: u64, limit: usize, guard: ?ReadGuard) !ReadResult {
        if (guard) |policy| try policy.check(p, null);
        // NOFOLLOW 拒绝符号链接；NONBLOCK 保证 FIFO 等特殊文件不会让 open 挂起。
        const fd = openAt(p.fd, p.name, .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
        if (fd < 0) return osError();
        defer closeFd(fd);
        if (guard) |policy| try policy.check(p, fd);
        const file = fileFromFd(fd);
        // 基于已打开的 fd 做 stat，而不是按路径重新查找，避免读取前后被替换（TOCTOU）。
        const stat = try file.stat(self.io);
        if (stat.kind != .file) return error.NotRegularFile;
        if (offset > stat.size or offset > std.math.maxInt(i64)) return error.InvalidOffset;

        // One bounded read includes up to 3 lookbehind bytes and 3 lookahead
        // bytes. Alignment and validation use the same fd and byte buffer.
        const before: usize = @intCast(@min(offset, 3));
        const window_offset = offset - before;
        const available = stat.size - window_offset;
        const wanted = std.math.add(u64, @intCast(limit), before + 3) catch available;
        const count = std.math.cast(usize, @min(available, wanted)) orelse return error.FileTooLarge;
        const buffer = try allocator.alloc(u8, count);
        defer allocator.free(buffer);

        // 读到的字节数与 stat 不符，说明文件在读取过程中被修改。
        const n = try file.readPositionalAll(self.io, buffer, window_offset);
        if (n != count) return error.FileChanged;
        var start = before;
        if (start < n) {
            while (start > 0 and buffer[start] & 0xc0 == 0x80) start -= 1;
            const width = std.unicode.utf8ByteSequenceLength(buffer[start]) catch return error.InvalidUtf8;
            // A stray continuation byte must not attach to an earlier ASCII or
            // already-complete character. Never skip malformed bytes forward.
            if (width <= before - start) return error.InvalidUtf8;
            if (start < before) {
                if (width > n - start) return error.InvalidUtf8;
                try validateText(buffer[start..][0..width]);
            }
        }
        const text = buffer[start..n];
        const actual_offset = window_offset + start;

        // 逐个 UTF-8 字符校验并累加；超过 limit 的字符不返回。若第一个字符本身就超限，说明 limit 太小。
        var end: usize = 0;
        while (end < @min(limit, text.len)) {
            const width = std.unicode.utf8ByteSequenceLength(text[end]) catch return error.InvalidUtf8;
            if (width > text.len - end) return error.InvalidUtf8;
            try validateText(text[end..][0..width]);
            if (width > limit - end) {
                if (end == 0 and limit != 0) return error.ReadLimitTooSmall;
                break;
            }
            end += width;
        }

        // truncated 表示返回的结束位置仍未到文件末尾。
        return .{ .data = try allocator.dupe(u8, text[0..end]), .offset = actual_offset, .total_bytes = stat.size, .truncated = actual_offset + end < stat.size };
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
        const old = openAt(p.fd, p.name, .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
        if (old >= 0) {
            defer closeFd(old);
            if (!overwrite) return error.PathAlreadyExists;
            const stat = try fileFromFd(old).stat(self.io);
            if (stat.kind != .file) return error.NotRegularFile;
            if (forced_mode == null) mode = stat.permissions.toMode() & 0o777;
            if (observed) |out| out.* = try self.observeChanges(old, stat.size, content);
        } else if (errno() != .NOENT) return osError() else if (observed) |out| {
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
            temp_fd = openAt(p.fd, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
            if (temp_fd >= 0) break;
            if (errno() != .EXIST) return osError();
        }
        if (temp_fd < 0) return error.TempNameExhausted;

        // defer 为后进先出：先 unlink 临时名，再关闭 fd。rename 成功后临时名已不存在，unlink 失败被忽略。
        defer closeFd(temp_fd);
        defer _ = std.c.unlinkat(p.fd, name, 0);

        try fileFromFd(temp_fd).writePositionalAll(self.io, content, 0);

        // 临时文件以 0600 创建，内容写完后才设为目标权限，避免写入期间权限过宽。
        const permissions = std.math.cast(std.c.mode_t, mode) orelse return error.InvalidFileMode;
        if (std.c.fchmod(temp_fd, permissions) != 0) return osError();

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

// 测试辅助：取得 TmpDir 的规范路径，并以它打开 Root。

// 测试：读写、范围读取、UTF-8 边界、覆盖失败与权限保留。

// libc 的 mkfifoat，测试用它在根目录下创建 FIFO，验证非普通文件会被拒绝且不阻塞。

// 测试：拒绝路径穿越、符号链接、目录与 FIFO，且不会阻塞。
