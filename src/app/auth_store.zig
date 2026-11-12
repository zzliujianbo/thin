//! 显式 HOME 下的凭据配置存储：目录 fd 锚定、有限读取、原子写入与密钥缓冲区擦除。
//! flock 仅约束同一 .thin 目录 inode 上的合作写入者；非合作写入者、目录替换及
//! 内容相同的 ABA 修改不在并发保证内。摘要检查不是针对恶意同用户进程的安全边界。
//! 不读取环境 HOME，不持久化锁文件；原子可见性不等同于断电持久性。

const std = @import("std");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const protocol = @import("../core/protocol.zig");

const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// 官方 DeepSeek 入门配置；未配置密钥时可加载，但不能发送提供方请求。
const initial: cfg.Config = .{
    .registry = .{
        .default = "deepseek/deepseek-flash",
        .reasoning_effort = "off",
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
            if (std.c.mkdirat(home_root.dir.handle, ".thin", 0o700) != 0 and fs.errno() != .EXIST)
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
            if (fs.flock(fd, fs.LOCK.EX | fs.LOCK.NB) == 0) return fd;
            const errno = fs.errno();
            if (errno != .AGAIN and errno != .INTR) return fs.osError();
            try std.Io.sleep(self.root.io, .fromMilliseconds(2), .awake);
        }
        return error.AuthStoreBusy;
    }

    /// A transaction holds the directory flock across a latest read and write.
    /// It must not outlive its Store, and must always be closed.
    pub const Transaction = struct {
        store: *Store,
        fd: c_int,

        pub fn deinit(self: *Transaction) void {
            fs.closeFd(self.fd);
            self.* = undefined;
        }

        pub fn loadLatest(self: *Transaction) !std.json.Parsed(cfg.Config) {
            self.store.expected_version = null;
            var bytes = (try self.store.read()) orelse return error.ConfigNotFound;
            defer bytes.deinit();
            const parsed = try cfg.parse(self.store.root.allocator, bytes.data());
            self.store.expected_version = digest(bytes.data());
            return parsed;
        }

        /// Caller must first loadLatest and modify that snapshot while holding this lock.
        pub fn saveLatest(self: *Transaction, config: cfg.Config) !void {
            const expected = self.store.expected_version orelse return error.AuthStoreNotLoaded;
            var bytes = try self.store.serialize(config);
            defer bytes.deinit();
            var current = (try self.store.read()) orelse return error.AuthVersionConflict;
            defer current.deinit();
            if (!std.mem.eql(u8, &expected, &digest(current.data()))) return error.AuthVersionConflict;
            try self.store.root.writeMode(cfg.file_name, bytes.data(), true, 0o600);
            self.store.expected_version = digest(bytes.data());
        }
    };

    /// Wait using the caller's original remaining budget; no ambient HOME lookup.
    pub fn beginTransaction(self: *Store, cancel: ?*const protocol.Cancellation, timeout_ms: u32) !Transaction {
        const fd = try fs.openDirectory(self.root.dir.handle, ".");
        errdefer fs.closeFd(fd);
        const started = std.Io.Clock.awake.now(self.root.io).toMilliseconds();
        while (true) {
            if (cancel) |c| if (c.isRequested()) return error.Cancelled;
            const elapsed = @max(0, std.Io.Clock.awake.now(self.root.io).toMilliseconds() -| started);
            if (elapsed >= timeout_ms) return error.AuthStoreBusy;
            if (fs.flock(fd, fs.LOCK.EX | fs.LOCK.NB) == 0) return .{ .store = self, .fd = fd };
            const errno = fs.errno();
            if (errno != .AGAIN and errno != .INTR) return fs.osError();
            try std.Io.sleep(self.root.io, .fromMilliseconds(2), .awake);
        }
    }

    /// 不跟随链接、不阻塞 FIFO；先检查 fd 类型，再读取最多上限加一字节。
    fn read(self: *Store) !?Bytes {
        const fd = fs.openAt(self.root.dir.handle, cfg.file_name, .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
        if (fd < 0) {
            if (fs.errno() == .NOENT) return null;
            return fs.osError();
        }
        defer fs.closeFd(fd);
        const file = fs.fileFromFd(fd);
        const stat = try file.stat(self.root.io);
        if (stat.kind != .file) return error.NotRegularFile;
        const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        var bytes = Bytes{
            .allocator = self.root.allocator,
            .buffer = try self.root.allocator.alloc(u8, try std.math.add(usize, size, 1)),
            .len = 0,
        };
        errdefer bytes.deinit();
        bytes.len = try file.readPositionalAll(self.root.io, bytes.buffer, 0);
        if (bytes.len != stat.size) return error.FileChanged;
        return bytes;
    }

    fn serialize(self: *Store, config: cfg.Config) !Bytes {
        try cfg.validate(config);
        var wiping = cfg.WipingAllocator{ .backing = self.root.allocator };
        var writer: std.Io.Writer.Allocating = .init(wiping.allocator());
        defer writer.deinit();
        // This writer has no I/O backend: WriteFailed is allocation failure.
        cfg.writeDisk(config, &writer.writer) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
        writer.writer.writeByte('\n') catch return error.OutOfMemory;
        const buffer = try writer.toOwnedSlice();
        return .{ .allocator = self.root.allocator, .buffer = buffer, .len = buffer.len };
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
