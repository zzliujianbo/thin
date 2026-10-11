//! 本地会话 JSONL：只持有目录/fd，不拥有 Root，不读取或清理旧日志。
//! 单线程调用；成功 append 表示完整行已交给内核，不表示 fsync 持久化。
const std = @import("std");
const filesystem = @import("../platform/filesystem.zig");
const ids = @import("session_id.zig");

pub const Limits = struct {
    /// 输入 JSON 的字节上限，不含附加的换行。
    record_bytes: usize = 2 * 1024 * 1024,
    /// 每个文件的硬上限，包含换行；单条记录不能跨文件。
    file_bytes: usize = 16 * 1024 * 1024,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    root: *filesystem.Root,
    limits: Limits,
    /// 仅在 start 成功后有效。
    session_id: [32]u8 = undefined,
    /// Set by the interactive lifecycle owner before the writer starts. The UI
    /// keeps its OWN immutable copy, never reads this worker-owned Store.
    pinned_id: ?ids.Id = null,
    part: u32 = 0,
    timestamp_ms: i64 = 0,
    logs_fd: ?c_int = null,
    file_fd: ?c_int = null,
    bytes: usize = 0,
    path_buffer: [128]u8 = undefined,
    path_len: usize = 0,
    failed: bool = false,

    /// 无 I/O；root 必须稳定存活到 Store.deinit 之后。
    pub fn init(allocator: std.mem.Allocator, root: *filesystem.Root, limits: Limits) Store {
        return .{ .allocator = allocator, .root = root, .limits = limits };
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
        if (std.c.mkdirat(parent, entry, 0o700) != 0 and std.c._errno().* != 17)
            return filesystem.osError();
        return filesystem.openDirectory(parent, entry);
    }

    fn name(buffer: []u8, timestamp: i64, id: [32]u8, part: u32) ![:0]u8 {
        return std.fmt.bufPrintSentinel(buffer, "{d}-{s}-{d}.jsonl", .{ timestamp, id, part }, 0);
    }

    fn createFile(self: *Store, dir_fd: c_int, filename: [:0]const u8) !c_int {
        const linux = filesystem.linux;
        const fd = linux.openat(dir_fd, filename, 1 | linux.create | linux.exclusive | linux.nofollow | linux.cloexec | linux.nonblock, 0o600);
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
        const linux = filesystem.linux;
        const created = linux.openat(dir_fd, ".gitignore", 1 | linux.create | linux.exclusive | linux.nofollow | linux.cloexec | linux.nonblock, 0o600);
        if (created >= 0) {
            defer filesystem.closeFd(created);
            if (std.c.fchmod(created, 0o600) != 0) return filesystem.osError();
            const file = filesystem.fileFromFd(created);
            if ((try file.stat(self.root.io)).kind != .file) return error.UnsafeLogIgnore;
            try file.writePositionalAll(self.root.io, "*\n", 0);
            return;
        }
        if (std.c._errno().* != 17) return filesystem.osError();
        const fd = linux.openat(dir_fd, ".gitignore", linux.nofollow | linux.cloexec | linux.nonblock, 0);
        if (fd < 0) return filesystem.osError();
        defer filesystem.closeFd(fd);
        const file = filesystem.fileFromFd(fd);
        const stat = try file.stat(self.root.io);
        if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0 or stat.size != 2)
            return error.UnsafeLogIgnore;
        // 最多读 3 字节，额外一字节检测 stat 后追加的内容。
        var buffer: [3]u8 = undefined;
        const n = try file.readPositionalAll(self.root.io, &buffer, 0);
        if (n != 2 or !std.mem.eql(u8, buffer[0..n], "*\n")) return error.UnsafeLogIgnore;
    }

    pub fn start(self: *Store) !void {
        try self.startTimestamp(null);
    }

    // Explicit timestamp is a private fixture seam for deterministic collision
    // checks. Normal callers always use the real clock.
    fn startTimestamp(self: *Store, supplied_timestamp: ?i64) !void {
        if (self.failed) return error.LogStoreFailed;
        if (self.file_fd != null) return;
        if (self.limits.record_bytes == 0 or self.limits.file_bytes == 0) return error.InvalidLimits;
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
            self.timestamp_ms = timestamp;
            self.part = 0;
            self.path_buffer = path_buffer;
            self.path_len = relative.len;
            self.logs_fd = logs_fd;
            self.file_fd = fd;
            self.bytes = 0;
            return;
        }
        return error.LogNameExhausted;
    }

    fn rotate(self: *Store) !void {
        const next = std.math.add(u32, self.part, 1) catch return error.LogPartExhausted;
        var buffer: [96]u8 = undefined;
        const filename = try name(&buffer, self.timestamp_ms, self.session_id, next);
        var path_buffer: [128]u8 = undefined;
        const relative = try std.fmt.bufPrint(&path_buffer, ".thin/sessions/{s}", .{filename});
        // 新文件完整建立后才释放旧 fd；任何失败都保留旧状态。
        const fd = try self.createFile(self.logs_fd.?, filename);
        filesystem.closeFd(self.file_fd.?);
        self.file_fd = fd;
        self.part = next;
        self.bytes = 0;
        self.path_buffer = path_buffer;
        self.path_len = relative.len;
    }

    /// 校验完整 JSON 对象后压紧空白，保留字符串、数字原文和键顺序。
    /// 所有校验/分配都在首次磁盘写入前完成；错误只返回错误码。
    pub fn append(self: *Store, json: []const u8) !void {
        if (self.failed) return error.LogStoreFailed;
        if (json.len > self.limits.record_bytes) return error.RecordTooLarge;
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
        if (n > self.limits.file_bytes) return error.RecordExceedsFileLimit;
        try self.start();
        if (n > self.limits.file_bytes - self.bytes) try self.rotate();
        // writePositionalAll 出错可能已写入前缀。封锁后续 append，不能重试覆盖半行。
        filesystem.fileFromFd(self.file_fd.?).writePositionalAll(self.root.io, line[0..n], self.bytes) catch |err| {
            self.failed = true;
            return err;
        };
        self.bytes += n;
    }
};

fn testRoot(dir: std.Io.Dir) !filesystem.Root {
    var buffer: [4096]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &buffer);
    return filesystem.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
}

fn expectContent(root: *filesystem.Root, path: []const u8, expected: []const u8) !void {
    const result = try root.read(std.testing.allocator, path, 0, 4096);
    defer std.testing.allocator.free(result.data);
    try std.testing.expect(!result.truncated);
    try std.testing.expectEqualStrings(expected, result.data);
}

test "pinned identity is lazy immutable and collision never substitutes another identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const id: ids.Id = @splat('b');
    var store = Store.init(std.testing.allocator, &root, .{});
    defer store.deinit();
    var invalid = id;
    invalid[0] = '\n';
    try std.testing.expectError(error.InvalidSessionID, store.pinSessionID(invalid));
    try std.testing.expect(store.pinned_id == null);
    try store.pinSessionID(id);
    try store.pinSessionID(id);
    try std.testing.expectError(error.SessionIDAlreadyPinned, store.pinSessionID(@splat('c')));
    try std.testing.expectError(error.FileNotFound, filesystem.openDirectory(root.dir.handle, ".thin"));
    try store.startTimestamp(1234);
    try std.testing.expectEqualSlices(u8, &id, &store.session_id);
    try std.testing.expectError(error.SessionIDAlreadyStarted, store.pinSessionID(id));
    try store.append("{}");
    var collision = Store.init(std.testing.allocator, &root, .{});
    defer collision.deinit();
    try collision.pinSessionID(id);
    try std.testing.expectError(error.LogNameExhausted, collision.startTimestamp(1234));
    try std.testing.expect(collision.file_fd == null and collision.logs_fd == null);
    try std.testing.expectEqualSlices(u8, &id, &collision.pinned_id.?);
    try expectContent(&root, store.path(), "{}\n");
}

test "log store lazy init private modes ordered compact lines and independent sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var store = Store.init(std.testing.allocator, &root, .{});
    defer store.deinit();
    try std.testing.expectEqualStrings("", store.path());
    try std.testing.expectError(error.FileNotFound, filesystem.openDirectory(root.dir.handle, ".thin"));
    try store.start();
    try std.testing.expect(std.mem.startsWith(u8, store.path(), ".thin/sessions/"));
    try std.testing.expectError(error.FileNotFound, root.dir.statFile(root.io, ".thin/logs", .{}));
    try expectContent(&root, ".thin/sessions/.gitignore", "*\n");
    const marker_stat = try root.dir.statFile(root.io, ".thin/sessions/.gitignore", .{});
    try std.testing.expectEqual(@as(u32, 0o600), marker_stat.permissions.toMode() & 0o777);
    const fd = store.file_fd.?;
    const original = try std.testing.allocator.dupe(u8, store.path());
    defer std.testing.allocator.free(original);
    try store.start();
    try std.testing.expectEqual(fd, store.file_fd.?);
    try expectContent(&root, store.path(), "");
    const dir_stat = try filesystem.fileFromFd(store.logs_fd.?).stat(root.io);
    const file_stat = try filesystem.fileFromFd(fd).stat(root.io);
    try std.testing.expectEqual(@as(u32, 0o700), dir_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u32, 0o600), file_stat.permissions.toMode() & 0o777);
    try store.append(" { \"a\": 1, \"s\": \"中 \\\" \\n\" } ");
    try store.append("{\"b\":2}");
    try expectContent(&root, original, "{\"a\":1,\"s\":\"中 \\\" \\n\"}\n{\"b\":2}\n");
    var other = Store.init(std.testing.allocator, &root, .{});
    defer other.deinit();
    try other.append("{}");
    try std.testing.expect(!std.mem.eql(u8, store.path(), other.path()));
    try std.testing.expect(!std.mem.eql(u8, &store.session_id, &other.session_id));
    try expectContent(&root, other.path(), "{}\n");
}

test "log store rotates without splitting or overwriting and keeps old fd on collision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var store = Store.init(std.testing.allocator, &root, .{ .record_bytes = 8, .file_bytes = 6 });
    defer store.deinit();
    try store.append("{}");
    const first = try std.testing.allocator.dupe(u8, store.path());
    defer std.testing.allocator.free(first);
    try store.append("{}");
    try std.testing.expectEqual(@as(u32, 0), store.part);
    try store.append("{}");
    try std.testing.expectEqual(@as(u32, 1), store.part);
    try expectContent(&root, first, "{}\n{}\n");
    try expectContent(&root, store.path(), "{}\n");
    try store.append("{}");
    var buffer: [96]u8 = undefined;
    const next = try Store.name(&buffer, store.timestamp_ms, store.session_id, 2);
    const collision = try store.createFile(store.logs_fd.?, next);
    defer filesystem.closeFd(collision);
    const old_fd = store.file_fd.?;
    try std.testing.expectError(error.PathAlreadyExists, store.append("{}"));
    try std.testing.expectEqual(old_fd, store.file_fd.?);
    try std.testing.expectEqual(@as(u32, 1), store.part);
    try expectContent(&root, store.path(), "{}\n{}\n");
    try std.testing.expectEqual(@as(u64, 0), (try filesystem.fileFromFd(collision).stat(root.io)).size);
}

test "log store invalid records and allocation failure do not create directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var store = Store.init(std.testing.allocator, &root, .{ .record_bytes = 16, .file_bytes = 6 });
    defer store.deinit();
    try std.testing.expectError(error.RecordTooLarge, store.append("{\"long\":123456789}"));
    try std.testing.expectError(error.RawNewline, store.append("{}\n"));
    try std.testing.expectError(error.RawNewline, store.append("{\r}"));
    try std.testing.expectError(error.InvalidUtf8, store.append("{\"a\":\"\xff\"}"));
    try std.testing.expectError(error.ExpectedJsonObject, store.append("[]"));
    try std.testing.expectError(error.InvalidJson, store.append("{\"a\":}"));
    try std.testing.expectError(error.InvalidJson, store.append("{}{}"));
    try std.testing.expectError(error.RecordExceedsFileLimit, store.append("{\"a\":1}"));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var oom = Store.init(failing.allocator(), &root, .{});
    defer oom.deinit();
    try std.testing.expectError(error.OutOfMemory, oom.append("{}"));
    try std.testing.expectError(error.FileNotFound, filesystem.openDirectory(root.dir.handle, ".thin"));
}

fn partialWriteFailure(_: ?*anyopaque, file: std.Io.File, _: []const u8, _: []const []const u8, _: usize, offset: u64) std.Io.File.WritePositionalError!usize {
    try file.writePositionalAll(std.testing.io, "{", offset);
    return error.NoSpaceLeft;
}

fn regularStatFailure(_: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
    const stat = try file.stat(std.testing.io);
    if (stat.kind == .file and stat.size == 0) return error.Unexpected;
    return stat;
}

test "log store partial write poisons store and creation failure closes owned fds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var vtable = root.io.vtable.*;
    root.io.vtable = &vtable;
    var store = Store.init(std.testing.allocator, &root, .{});
    defer store.deinit();
    // 先准备有效 marker，下面的 stat 故障只用于日志新文件。
    const thin = try Store.directory(root.dir.handle, ".thin");
    defer filesystem.closeFd(thin);
    const logs = try Store.directory(thin, "sessions");
    defer filesystem.closeFd(logs);
    try store.ensureIgnore(logs);
    vtable.fileStat = regularStatFailure;
    const before = try openFdCount();
    for (0..8) |_| try std.testing.expectError(error.Unexpected, store.start());
    try std.testing.expectEqual(before, try openFdCount());
    try std.testing.expect(store.file_fd == null and store.logs_fd == null);
    try std.testing.expectEqualStrings("", store.path());
    vtable.fileStat = std.testing.io.vtable.fileStat;
    try store.append("{}");
    vtable.fileWritePositional = partialWriteFailure;
    try std.testing.expectError(error.NoSpaceLeft, store.append("{}"));
    try std.testing.expectEqual(@as(usize, 3), store.bytes);
    try expectContent(&root, store.path(), "{}\n{");
    try std.testing.expectError(error.LogStoreFailed, store.append("{}"));
    try std.testing.expectError(error.LogStoreFailed, store.start());
    try expectContent(&root, store.path(), "{}\n{");
    store.deinit();
    try std.testing.expectEqual(before, try openFdCount());
}

fn jsonlCount(root: *filesystem.Root) !usize {
    var dir = try root.dir.openDir(root.io, ".thin/sessions", .{ .iterate = true });
    defer dir.close(root.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(root.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".jsonl")) count += 1;
    }
    return count;
}

test "log store ignore marker rejects unsafe modes content symlinks FIFO and directories" {
    for (0..10) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root = try testRoot(tmp.dir);
        defer root.deinit();
        const thin = try Store.directory(root.dir.handle, ".thin");
        defer filesystem.closeFd(thin);
        const logs = try Store.directory(thin, "sessions");
        defer filesystem.closeFd(logs);
        switch (case) {
            7 => try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("missing", logs, ".gitignore")),
            8 => try std.testing.expectEqual(@as(c_int, 0), mkfifoat(logs, ".gitignore", 0o600)),
            9 => try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(logs, ".gitignore", 0o700)),
            else => {
                const content = switch (case) {
                    3 => "",
                    4 => "*",
                    5 => "*\nx",
                    6 => "x\n",
                    else => "*\n",
                };
                try root.write(".thin/sessions/.gitignore", content, false);
                const mode: u32 = switch (case) {
                    0 => 0o644,
                    1 => 0o640,
                    2 => 0o604,
                    else => 0o600,
                };
                try std.testing.expectEqual(@as(c_int, 0), std.c.fchmodat(logs, ".gitignore", mode, 0));
            },
        }
        var store = Store.init(std.testing.allocator, &root, .{});
        defer store.deinit();
        const before = try openFdCount();
        for (0..4) |_| {
            if (case == 7) {
                try std.testing.expectError(error.SymlinkNotAllowed, store.append("{}"));
            } else {
                try std.testing.expectError(error.UnsafeLogIgnore, store.append("{}"));
            }
        }
        try std.testing.expectEqual(before, try openFdCount());
        try std.testing.expectEqual(@as(usize, 0), try jsonlCount(&root));
        try std.testing.expectEqualStrings("", store.path());
        if (case < 3) {
            try expectContent(&root, ".thin/sessions/.gitignore", "*\n");
            const stat = try root.dir.statFile(root.io, ".thin/sessions/.gitignore", .{});
            try std.testing.expect(stat.permissions.toMode() & 0o077 != 0);
        }
    }
}

test "log store marker partial creation fails closed without leaking or creating logs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var vtable = root.io.vtable.*;
    root.io.vtable = &vtable;
    vtable.fileWritePositional = partialWriteFailure;
    var store = Store.init(std.testing.allocator, &root, .{});
    defer store.deinit();
    const before = try openFdCount();
    try std.testing.expectError(error.NoSpaceLeft, store.append("{}"));
    try std.testing.expectEqual(before, try openFdCount());
    try std.testing.expectEqual(@as(usize, 0), try jsonlCount(&root));
    vtable.fileWritePositional = std.testing.io.vtable.fileWritePositional;
    try std.testing.expectError(error.UnsafeLogIgnore, store.append("{}"));
    try expectContent(&root, ".thin/sessions/.gitignore", "{");
    try std.testing.expectEqual(before, try openFdCount());
}

// 只枚举自身 fd，不读取用户配置或 HOME。
fn openFdCount() !usize {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/proc/self/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}

extern "c" fn mkfifoat(c_int, [*:0]const u8, c_uint) c_int;

test "log store rejects symlink regular file and FIFO at either directory component" {
    for (0..2) |level| {
        for (0..3) |kind| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var root = try testRoot(tmp.dir);
            defer root.deinit();
            const parent = if (level == 0) try filesystem.openDirectory(root.dir.handle, ".") else try Store.directory(root.dir.handle, ".thin");
            defer filesystem.closeFd(parent);
            const entry: [:0]const u8 = if (level == 0) ".thin" else "sessions";
            switch (kind) {
                0 => try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat(".", parent, entry)),
                1 => {
                    const fd = filesystem.linux.openat(parent, entry, 1 | filesystem.linux.create | filesystem.linux.exclusive, 0o600);
                    try std.testing.expect(fd >= 0);
                    filesystem.closeFd(fd);
                },
                2 => try std.testing.expectEqual(@as(c_int, 0), mkfifoat(parent, entry, 0o600)),
                else => unreachable,
            }
            var store = Store.init(std.testing.allocator, &root, .{});
            defer store.deinit();
            // 多次失败始终不拥有 fd；外部有界测试也验证 FIFO 不阻塞。
            const before = try openFdCount();
            for (0..8) |_| try std.testing.expectError(error.NotDir, store.start());
            try std.testing.expectEqual(before, try openFdCount());
            try std.testing.expect(store.file_fd == null and store.logs_fd == null);
            try std.testing.expectEqualStrings("", store.path());
        }
    }
}

test "log store rejects insecure existing logs without chmod and preserves thin permissions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const thin = try Store.directory(root.dir.handle, ".thin");
    defer filesystem.closeFd(thin);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(thin, 0o755));
    const logs = try Store.directory(thin, "sessions");
    defer filesystem.closeFd(logs);
    var store = Store.init(std.testing.allocator, &root, .{});
    defer store.deinit();
    for ([_]u32{ 0o710, 0o701, 0o777 }) |mode| {
        try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(logs, mode));
        const before = try openFdCount();
        for (0..8) |_| try std.testing.expectError(error.UnsafeLogDirectory, store.start());
        try std.testing.expectEqual(before, try openFdCount());
        try std.testing.expectEqual(mode, (try filesystem.fileFromFd(logs).stat(root.io)).permissions.toMode() & 0o777);
        try std.testing.expect(store.logs_fd == null and store.file_fd == null);
    }
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmod(logs, 0o700));
    try store.append("{}");
    try std.testing.expectEqual(@as(u32, 0o755), (try filesystem.fileFromFd(thin).stat(root.io)).permissions.toMode() & 0o777);
    store.deinit();
    // deinit 不接管或关闭 root；也可重复清理。
    try root.write("root-still-owned", "ok", false);
}
