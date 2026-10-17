//! 显式 HOME 下的凭据配置存储：目录 fd 锚定、有限读取、原子写入与密钥缓冲区擦除。
//! flock 仅约束同一 .thin 目录 inode 上的合作写入者；非合作写入者、目录替换及
//! 内容相同的 ABA 修改不在并发保证内。摘要检查不是针对恶意同用户进程的安全边界。
//! 不读取环境 HOME，不持久化锁文件；原子可见性不等同于断电持久性。

const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");

const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// 官方 DeepSeek 入门配置；未配置密钥时可加载，但不能发送提供方请求。
const initial: cfg.Config = .{
    .registry = .{
        .default = "deepseek/deepseek-flash",
        .reasoning_effort = "medium",
        .providers = &.{.{
            .name = "deepseek",
            .connection = .{ .base_url = "https://api.deepseek.com", .kind = .deepseek, .chat_max_tokens = true },
            .models = &.{.{ .name = "deepseek-flash", .patch = .{ .protocol = .chat, .context_tokens = 1000000 } }},
        }},
    },
    .selected_provider = "deepseek",
    .provider = .{ .base_url = "https://api.deepseek.com", .kind = .deepseek, .chat_max_tokens = true },
    .model = .{ .name = "deepseek-flash", .context_tokens = 1000000, .protocol = .chat },
};

/// 整块分配始终保留到擦除，避免缩容时留下带密钥的旧缓冲区。
const Bytes = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    len: usize,

    fn data(self: Bytes) []const u8 {
        return self.buffer[0..self.len];
    }

    fn deinit(self: *Bytes) void {
        std.crypto.secureZero(u8, self.buffer);
        self.allocator.free(self.buffer);
        self.* = undefined;
    }
};

pub const Store = struct {
    root: fs.Root,
    /// null 表示尚未成功加载，save 不允许在没有版本基线时覆盖配置。
    expected_version: ?Digest = null,

    pub fn open(a: std.mem.Allocator, io: std.Io, home: []const u8) !Store {
        return openMode(a, io, home, true);
    }

    pub fn openExisting(a: std.mem.Allocator, io: std.Io, home: []const u8) !Store {
        return openMode(a, io, home, false);
    }

    fn openMode(a: std.mem.Allocator, io: std.Io, home: []const u8, create: bool) !Store {
        // 复用配置层的绝对 HOME 校验；绝不探测真实 HOME 或环境变量。
        const auth_path = try cfg.defaultPath(a, home);
        defer a.free(auth_path);
        var home_root = try fs.Root.open(a, io, home);
        defer home_root.deinit();

        const fd = fs.openDirectory(home_root.dir.handle, ".thin") catch |err| blk: {
            if (!create or err != error.FileNotFound) return err;
            if (std.c.mkdirat(home_root.dir.handle, ".thin", 0o700) != 0 and std.c._errno().* != 17)
                return fs.osError();
            break :blk try fs.openDirectory(home_root.dir.handle, ".thin");
        };
        errdefer fs.closeFd(fd);
        return .{ .root = .{
            .dir = .{ .handle = fd },
            .path = try std.fs.path.join(a, &.{ home_root.path, ".thin" }),
            .io = io,
            .allocator = a,
        } };
    }

    pub fn deinit(self: *Store) void {
        self.root.deinit();
        self.* = undefined;
    }

    /// 每次重新打开目录，得到独立 open description；同进程不同 Store 也互斥。
    /// 最多尝试 100 次（通常约 200ms），包括 EINTR；不会无限等待。
    fn lock(self: *Store) !c_int {
        const fd = try fs.openDirectory(self.root.dir.handle, ".");
        errdefer fs.closeFd(fd);
        for (0..100) |_| {
            if (fs.linux.flock(fd, 2 | 4) == 0) return fd;
            const errno = std.c._errno().*;
            if (errno != 11 and errno != 4) return fs.osError();
            try std.Io.sleep(self.root.io, .fromMilliseconds(2), .awake);
        }
        return error.AuthStoreBusy;
    }

    /// 不跟随链接、不阻塞 FIFO；先检查 fd 类型，再读取最多上限加一字节。
    fn read(self: *Store) !?Bytes {
        const fd = fs.linux.openat(self.root.dir.handle, cfg.file_name, fs.linux.nofollow | fs.linux.cloexec | fs.linux.nonblock, 0);
        if (fd < 0) {
            if (std.c._errno().* == 2) return null;
            return fs.osError();
        }
        defer fs.closeFd(fd);
        const file = fs.fileFromFd(fd);
        const stat = try file.stat(self.root.io);
        if (stat.kind != .file) return error.NotRegularFile;
        if (stat.size > cfg.max_config_bytes) return error.ConfigTooLarge;
        var bytes = Bytes{
            .allocator = self.root.allocator,
            .buffer = try self.root.allocator.alloc(u8, cfg.max_config_bytes + 1),
            .len = 0,
        };
        errdefer bytes.deinit();
        bytes.len = try file.readPositionalAll(self.root.io, bytes.buffer, 0);
        if (bytes.len > cfg.max_config_bytes) return error.ConfigTooLarge;
        if (bytes.len != stat.size) return error.FileChanged;
        return bytes;
    }

    fn serialize(self: *Store, config: cfg.Config) !Bytes {
        try cfg.validate(config);
        var bytes = Bytes{
            .allocator = self.root.allocator,
            .buffer = try self.root.allocator.alloc(u8, cfg.max_config_bytes),
            .len = 0,
        };
        errdefer bytes.deinit();
        var writer = std.Io.Writer.fixed(bytes.buffer);
        cfg.writeDisk(config, &writer) catch |err| switch (err) {
            error.WriteFailed => return error.ConfigTooLarge,
            else => return err,
        };
        writer.writeByte('\n') catch return error.ConfigTooLarge;
        bytes.len = writer.end;
        return bytes;
    }

    /// Restore path: load an existing valid configuration, never initialize it.
    pub fn loadExisting(self: *Store) !std.json.Parsed(cfg.Config) {
        const fd = try self.lock();
        defer fs.closeFd(fd);
        self.expected_version = null;
        var bytes = (try self.read()) orelse return error.ConfigNotFound;
        defer bytes.deinit();
        const parsed = try cfg.parse(self.root.allocator, bytes.data());
        self.expected_version = digest(bytes.data());
        return parsed;
    }

    /// 只有缺失或 JSON 空白文件才初始化；任何非空内容都交给严格解析，失败不写回。
    /// 返回值必须使用 cfg.release 释放。
    pub fn loadOrInitialize(self: *Store) !std.json.Parsed(cfg.Config) {
        const fd = try self.lock();
        defer fs.closeFd(fd);
        // 失败的重新加载不能保留之前的保存权限。
        self.expected_version = null;
        var existing = try self.read();
        defer if (existing) |*bytes| bytes.deinit();
        if (existing) |bytes| {
            if (std.mem.trim(u8, bytes.data(), " \t\r\n").len != 0) {
                const parsed = try cfg.parse(self.root.allocator, bytes.data());
                self.expected_version = digest(bytes.data());
                return parsed;
            }
        }

        var bytes = try self.serialize(initial);
        defer bytes.deinit();
        var parsed = try cfg.parse(self.root.allocator, bytes.data());
        errdefer cfg.release(&parsed);
        // 缺失时 linkat 保证 no-replace；空文件与显式保存用强制 0600 原子替换。
        try self.root.writeMode(cfg.file_name, bytes.data(), existing != null, 0o600);
        self.expected_version = digest(bytes.data());
        return parsed;
    }

    /// 显式授权保存：仍使用相同配置 schema，成功后推进内容摘要基线。
    pub fn save(self: *Store, config: cfg.Config) !void {
        const expected = self.expected_version orelse return error.AuthStoreNotLoaded;
        var bytes = try self.serialize(config);
        defer bytes.deinit();
        const fd = try self.lock();
        defer fs.closeFd(fd);
        var current = (try self.read()) orelse return error.AuthVersionConflict;
        defer current.deinit();
        if (!std.mem.eql(u8, &expected, &digest(current.data()))) return error.AuthVersionConflict;
        try self.root.writeMode(cfg.file_name, bytes.data(), true, 0o600);
        self.expected_version = digest(bytes.data());
    }
};

fn digest(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn testOpen(dir: std.Io.Dir) !Store {
    var path: [4096]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &path);
    return Store.open(std.testing.allocator, std.testing.io, path[0..n]);
}

test "restore auth loading never creates or initializes configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    try std.testing.expectError(error.FileNotFound, Store.openExisting(std.testing.allocator, std.testing.io, home));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, ".thin", .{}));
    var store = try Store.open(std.testing.allocator, std.testing.io, home);
    defer store.deinit();
    try std.testing.expectError(error.ConfigNotFound, store.loadExisting());
    try store.root.dir.writeFile(std.testing.io, .{ .sub_path = cfg.file_name, .data = "  " });
    if (store.loadExisting()) |value| {
        var unexpected = value;
        cfg.release(&unexpected);
        return error.InitializedEmptyConfig;
    } else |_| {}
    const result = try store.root.read(std.testing.allocator, cfg.file_name, 0, 128);
    defer std.testing.allocator.free(result.data);
    try std.testing.expectEqualStrings("  ", result.data);
    try std.testing.expect(store.expected_version == null);
}

test "auth store missing and empty initialize once with private modes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    var parsed = try store.loadOrInitialize();
    defer cfg.release(&parsed);
    try std.testing.expectEqualStrings("deepseek-flash", parsed.value.model.name);
    try std.testing.expectEqualStrings("https://api.deepseek.com", parsed.value.provider.base_url);
    try std.testing.expect(parsed.value.selection_pending);
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", parsed.value.registry.?.default);
    const patch = parsed.value.registry.?.find("deepseek").?.patchFor("deepseek-flash").?;
    try std.testing.expectEqual(@as(?u32, 1000000), patch.context_tokens);
    try std.testing.expectEqual(.chat, patch.protocol.?);
    try std.testing.expect(parsed.value.provider.api_key == null);
    try std.testing.expect(parsed.value.provider.chat_max_tokens);
    try std.testing.expectEqualStrings("", parsed.value.provider.api_key_env);
    const dir_stat = try tmp.dir.statFile(io, ".thin", .{});
    try std.testing.expectEqual(@as(u32, 0o700), dir_stat.permissions.toMode() & 0o777);
    const stat = try store.root.dir.statFile(io, cfg.file_name, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    const version = store.expected_version.?;
    var again = try store.loadOrInitialize();
    defer cfg.release(&again);
    try std.testing.expectEqual(version, store.expected_version.?);
    const same = try store.root.dir.statFile(io, cfg.file_name, .{});
    try std.testing.expectEqual(stat.inode, same.inode);

    for ([_][]const u8{ "", " \t\r\n" }) |empty| {
        try store.root.dir.writeFile(io, .{ .sub_path = cfg.file_name, .data = empty });
        try std.testing.expectEqual(@as(c_int, 0), std.c.fchmodat(store.root.dir.handle, cfg.file_name, 0o644, 0));
        var initialized = try store.loadOrInitialize();
        defer cfg.release(&initialized);
        const mode = try store.root.dir.statFile(io, cfg.file_name, .{});
        try std.testing.expectEqual(@as(u32, 0o600), mode.permissions.toMode() & 0o777);
        try std.testing.expectEqual(version, store.expected_version.?);
    }
}

test "auth store preserves every nonempty invalid file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    for ([_][]const u8{ "{", "not json", "{}", "\x00", "\x0b", "{\"provider\":{\"api_key\":\"fake-secret\"},\"unknown\":1}", "{\"provider\":{\"base_url\":\"https://api.deepseek.com\"},\"model\":{\"name\":\"deepseek-flash\",\"context_tokens\":1000000}}" }) |invalid| {
        try store.root.dir.writeFile(std.testing.io, .{ .sub_path = cfg.file_name, .data = invalid });
        if (store.loadOrInitialize()) |result| {
            var unexpected = result;
            cfg.release(&unexpected);
            return error.ExpectedInvalidConfig;
        } else |_| {}
        var current = (try store.read()).?;
        defer current.deinit();
        try std.testing.expectEqualStrings(invalid, current.data());
        try std.testing.expect(store.expected_version == null);
    }
}

test "auth store rejects legacy disk and runtime-only saves without overwriting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    const legacy =
        \\{"provider":{"base_url":"https://api.deepseek.com"},"model":{"name":"deepseek-flash","context_tokens":1000000}}
    ;
    try store.root.dir.writeFile(std.testing.io, .{ .sub_path = cfg.file_name, .data = legacy });
    try std.testing.expectError(error.UnknownField, store.loadOrInitialize());
    try std.testing.expectError(error.UnknownField, store.loadExisting());
    try std.testing.expect(store.expected_version == null);
    var old_bytes = (try store.read()).?;
    defer old_bytes.deinit();
    try std.testing.expectEqualStrings(legacy, old_bytes.data());
    try store.root.dir.deleteFile(std.testing.io, cfg.file_name);
    var parsed = try store.loadOrInitialize();
    defer cfg.release(&parsed);
    const version = store.expected_version.?;
    var runtime_only = initial;
    runtime_only.registry = null;
    try std.testing.expectError(error.MissingRegistry, store.save(runtime_only));
    try std.testing.expectEqual(version, store.expected_version.?);
    var unchanged = try store.loadExisting();
    defer cfg.release(&unchanged);
    try std.testing.expectEqual(version, store.expected_version.?);
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", unchanged.value.registry.?.default);
}

test "auth store explicit save mode and version conflict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var one = try testOpen(tmp.dir);
    defer one.deinit();
    try std.testing.expectError(error.AuthStoreNotLoaded, one.save(initial));
    var parsed = try one.loadOrInitialize();
    defer cfg.release(&parsed);
    var two = try testOpen(tmp.dir);
    defer two.deinit();
    var second = try two.loadOrInitialize();
    defer cfg.release(&second);
    var changed = try cfg.clone(std.testing.allocator, parsed.value);
    defer cfg.release(&changed);
    try cfg.setRegistryCredential(changed.arena.allocator(), &changed.value, "deepseek", "fake-secret-only");
    try std.testing.expectEqual(@as(c_int, 0), std.c.fchmodat(one.root.dir.handle, cfg.file_name, 0o644, 0));
    try one.save(changed.value);
    try std.testing.expectError(error.AuthVersionConflict, two.save(initial));
    try one.save(changed.value);
    const stat = try one.root.dir.statFile(std.testing.io, cfg.file_name, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    var loaded = try two.loadOrInitialize();
    defer cfg.release(&loaded);
    try std.testing.expectEqualStrings("fake-secret-only", loaded.value.provider.api_key.?);
    // 非空且合法的文件也不应被引导模板改写。
    const saved_version = two.expected_version.?;
    var stable = try two.loadOrInitialize();
    defer cfg.release(&stable);
    try std.testing.expectEqual(saved_version, two.expected_version.?);
    try one.root.dir.deleteFile(std.testing.io, cfg.file_name);
    try std.testing.expectError(error.AuthVersionConflict, one.save(changed.value));
}

extern "c" fn mkfifoat(c_int, [*:0]const u8, c_uint) c_int;

test "auth store rejects symlink directory FIFO and oversize config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testOpen(tmp.dir);
    defer store.deinit();
    const fd = store.root.dir.handle;
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("missing-fake-target", fd, cfg.file_name));
    try std.testing.expectError(error.SymlinkNotAllowed, store.loadOrInitialize());
    try store.root.dir.deleteFile(std.testing.io, cfg.file_name);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(fd, cfg.file_name, 0o700));
    try std.testing.expectError(error.NotRegularFile, store.loadOrInitialize());
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlinkat(fd, cfg.file_name, 0x200));
    try std.testing.expectEqual(@as(c_int, 0), mkfifoat(fd, cfg.file_name, 0o600));
    try std.testing.expectError(error.NotRegularFile, store.loadOrInitialize());
    try store.root.dir.deleteFile(std.testing.io, cfg.file_name);
    const big = try std.testing.allocator.alloc(u8, cfg.max_config_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, ' ');
    try store.root.dir.writeFile(std.testing.io, .{ .sub_path = cfg.file_name, .data = big });
    try std.testing.expectError(error.ConfigTooLarge, store.loadOrInitialize());
}

test "auth store rejects linked thin directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat(".", tmp.dir.handle, ".thin"));
    try std.testing.expectError(error.NotDir, testOpen(tmp.dir));
}

test "auth store independent directory locks have bounded contention" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var one = try testOpen(tmp.dir);
    defer one.deinit();
    var two = try testOpen(tmp.dir);
    defer two.deinit();
    const fd = try one.lock();
    defer fs.closeFd(fd);
    try std.testing.expectError(error.AuthStoreBusy, two.loadOrInitialize());
}
