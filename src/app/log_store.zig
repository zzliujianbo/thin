//! 本地会话 JSONL：只持有目录/fd，不拥有 Root，不读取或清理旧日志。
//! 单线程调用；成功 append 表示完整行已交给内核，不表示 fsync 持久化。
const std = @import("std");
const filesystem = @import("../platform/filesystem.zig");
const ids = @import("session_id.zig");

fn validateIgnore(io: std.Io, dir_fd: c_int) !void {
    const fd = filesystem.openAt(dir_fd, ".gitignore", .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
    if (fd < 0) return filesystem.osError();
    defer filesystem.closeFd(fd);
    const file = filesystem.fileFromFd(fd);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0 or stat.size != 2)
        return error.UnsafeLogIgnore;
    var buffer: [3]u8 = undefined;
    const n = try file.readPositionalAll(io, &buffer, 0);
    if (n != 2 or !std.mem.eql(u8, buffer[0..n], "*\n")) return error.UnsafeLogIgnore;
}

/// Read-only access to the same protected namespace. Never create a directory,
/// marker or archive just to read an existing checkpoint.
pub fn openExistingDirectory(root: *filesystem.Root) !c_int {
    const thin_fd = try filesystem.openDirectory(root.dir.handle, ".thin");
    defer filesystem.closeFd(thin_fd);
    const fd = try filesystem.openDirectory(thin_fd, "sessions");
    errdefer filesystem.closeFd(fd);
    const stat = try filesystem.fileFromFd(fd).stat(root.io);
    if (stat.kind != .directory or stat.permissions.toMode() & 0o077 != 0) return error.UnsafeLogDirectory;
    try validateIgnore(root.io, fd);
    return fd;
}

/// Create only the private namespace/ignore marker, never a diagnostic archive.
/// Shared by the exit-checkpoint writer; help, version and reads never call it.
pub fn openCheckpointDirectory(root: *filesystem.Root) !c_int {
    const thin_fd = try Store.directory(root.dir.handle, ".thin");
    defer filesystem.closeFd(thin_fd);
    const fd = try Store.directory(thin_fd, "sessions");
    errdefer filesystem.closeFd(fd);
    const stat = try filesystem.fileFromFd(fd).stat(root.io);
    if (stat.kind != .directory or stat.permissions.toMode() & 0o077 != 0) return error.UnsafeLogDirectory;
    var owner = Store.init(root.allocator, root);
    try owner.ensureIgnore(fd);
    return fd;
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    root: *filesystem.Root,
    /// 仅在 start 成功后有效。
    session_id: [32]u8 = undefined,
    /// Set by the interactive lifecycle owner before the writer starts. The UI
    /// keeps its OWN immutable copy, never reads this worker-owned Store.
    pinned_id: ?ids.Id = null,
    logs_fd: ?c_int = null,
    file_fd: ?c_int = null,
    bytes: usize = 0,
    path_buffer: [128]u8 = undefined,
    path_len: usize = 0,
    failed: bool = false,

    /// 无 I/O；root 必须稳定存活到 Store.deinit 之后。
    pub fn init(allocator: std.mem.Allocator, root: *filesystem.Root) Store {
        return .{ .allocator = allocator, .root = root };
    }

    /// No I/O, no archive creation; called only before writer ownership begins.
    pub fn pinSessionID(self: *Store, id: ids.Id) !void {
        if (!ids.valid(id)) return error.InvalidSessionID;
        if (self.failed or self.file_fd != null or self.logs_fd != null) return error.SessionIDAlreadyStarted;
        if (self.pinned_id) |old| if (!std.mem.eql(u8, &old, &id)) return error.SessionIDAlreadyPinned;
        self.pinned_id = id;
    }

    /// 返回借用切片；start 前为空，下一次轮转会使旧切片失效。
    pub fn path(self: *const Store) []const u8 {
        return self.path_buffer[0..self.path_len];
    }

    pub fn deinit(self: *Store) void {
        if (self.file_fd) |fd| filesystem.closeFd(fd);
        if (self.logs_fd) |fd| filesystem.closeFd(fd);
        self.file_fd = null;
        self.logs_fd = null;
        self.path_len = 0;
        self.failed = true;
    }

    fn directory(parent: c_int, entry: [*:0]const u8) !c_int {
        if (std.c.mkdirat(parent, entry, 0o700) != 0 and filesystem.errno() != .EXIST)
            return filesystem.osError();
        return filesystem.openDirectory(parent, entry);
    }

    fn name(buffer: []u8, timestamp: i64, id: [32]u8, part: u32) ![:0]u8 {
        return std.fmt.bufPrintSentinel(buffer, "{s}-{d}-{d}.jsonl", .{ id, timestamp, part }, 0);
    }

    fn createFile(self: *Store, dir_fd: c_int, filename: [:0]const u8) !c_int {
        const fd = filesystem.openAt(dir_fd, filename, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0o600);
        if (fd < 0) return filesystem.osError();
        // 失败也不删除已创建文件；可能为空，但绝不覆盖任何已存在路径。
        errdefer filesystem.closeFd(fd);
        if (std.c.fchmod(fd, 0o600) != 0) return filesystem.osError();
        const stat = try filesystem.fileFromFd(fd).stat(self.root.io);
        if (stat.kind != .file) return error.NotRegularFile;
        return fd;
    }

    /// marker 必须先于日志存在；不覆盖已有内容，失败遗留的半个 marker 也拒绝。
    fn ensureIgnore(self: *Store, dir_fd: c_int) !void {
        // startTimestamp owns an independent open description for this directory.
        // Cooperating starters must not inspect a marker still being initialized.
        // Lock only this inode, bounded/cancellable; no lockfile or fsync promise.
        var locked = false;
        for (0..100) |_| {
            if (filesystem.flock(dir_fd, filesystem.LOCK.EX | filesystem.LOCK.NB) == 0) {
                locked = true;
                break;
            }
            const errno = filesystem.errno();
            if (errno != .AGAIN and errno != .INTR) return filesystem.osError();
            try std.Io.sleep(self.root.io, .fromMilliseconds(2), .awake);
        }
        if (!locked) return error.LogStoreBusy;
        defer _ = filesystem.flock(dir_fd, filesystem.LOCK.UN);
        const created = filesystem.openAt(dir_fd, ".gitignore", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0o600);
        if (created >= 0) {
            defer filesystem.closeFd(created);
            if (std.c.fchmod(created, 0o600) != 0) return filesystem.osError();
            const file = filesystem.fileFromFd(created);
            if ((try file.stat(self.root.io)).kind != .file) return error.UnsafeLogIgnore;
            try file.writePositionalAll(self.root.io, "*\n", 0);
            return;
        }
        if (filesystem.errno() != .EXIST) return filesystem.osError();
        try validateIgnore(self.root.io, dir_fd);
    }

    pub fn start(self: *Store) !void {
        try self.startTimestamp(null);
    }

    // Explicit timestamp is a private fixture seam for deterministic collision
    // checks. Normal callers always use the real clock.
    fn startTimestamp(self: *Store, supplied_timestamp: ?i64) !void {
        if (self.failed) return error.LogStoreFailed;
        if (self.file_fd != null) return;
        const thin_fd = try directory(self.root.dir.handle, ".thin");
        defer filesystem.closeFd(thin_fd);
        const logs_fd = try directory(thin_fd, "sessions");
        errdefer filesystem.closeFd(logs_fd);
        const stat = try filesystem.fileFromFd(logs_fd).stat(self.root.io);
        if (stat.kind != .directory) return error.NotDir;
        // 已有用户目录不 chmod；.thin 的已有权限也保持不变。
        if (stat.permissions.toMode() & 0o077 != 0) return error.UnsafeLogDirectory;
        try self.ensureIgnore(logs_fd);

        const timestamp = supplied_timestamp orelse std.Io.Clock.real.now(self.root.io).toMilliseconds();
        var buffer: [96]u8 = undefined;
        for (0..32) |_| {
            const id = self.pinned_id orelse try ids.generate(self.root.io);
            const filename = try name(&buffer, timestamp, id, 0);
            var path_buffer: [128]u8 = undefined;
            const relative = try std.fmt.bufPrint(&path_buffer, ".thin/sessions/{s}", .{filename});
            const fd = self.createFile(logs_fd, filename) catch |err| {
                if (err == error.PathAlreadyExists) {
                    // Never replace an identity already announced by its owner.
                    if (self.pinned_id != null) return error.LogNameExhausted;
                    continue;
                }
                return err;
            };
            self.session_id = id;
            self.path_buffer = path_buffer;
            self.path_len = relative.len;
            self.logs_fd = logs_fd;
            self.file_fd = fd;
            self.bytes = 0;
            return;
        }
        return error.LogNameExhausted;
    }

    /// 校验完整 JSON 对象后压紧空白，保留字符串、数字原文和键顺序。
    /// 所有校验/分配都在首次磁盘写入前完成；错误只返回错误码。
    pub fn append(self: *Store, json: []const u8) !void {
        if (self.failed) return error.LogStoreFailed;
        if (!std.unicode.utf8ValidateSlice(json)) return error.InvalidUtf8;
        if (std.mem.findAny(u8, json, "\r\n") != null) return error.RawNewline;
        const trimmed = std.mem.trim(u8, json, " \t");
        if (trimmed.len == 0 or trimmed[0] != '{') return error.ExpectedJsonObject;
        if (!try std.json.validate(self.allocator, json)) return error.InvalidJson;
        const capacity = std.math.add(usize, json.len, 1) catch return error.RecordTooLarge;
        const line = try self.allocator.alloc(u8, capacity);
        defer self.allocator.free(line);
        var n: usize = 0;
        var in_string = false;
        var escaped = false;
        for (json) |c| {
            if (!in_string and (c == ' ' or c == '\t')) continue;
            line[n] = c;
            n += 1;
            if (in_string) {
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    in_string = false;
                }
            } else if (c == '"') {
                in_string = true;
            }
        }
        line[n] = '\n';
        n += 1;
        const end = std.math.add(usize, self.bytes, n) catch return error.RecordTooLarge;
        try self.start();
        // writePositionalAll 出错可能已写入前缀。封锁后续 append，不能重试覆盖半行。
        filesystem.fileFromFd(self.file_fd.?).writePositionalAll(self.root.io, line[0..n], self.bytes) catch |err| {
            self.failed = true;
            return err;
        };
        self.bytes = end;
    }
};

// 只枚举自身 fd，不读取用户配置或 HOME。
