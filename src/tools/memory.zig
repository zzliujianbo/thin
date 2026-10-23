//! Shared explicit and evidence-grounded automatic project memory. Never a
//! conversation log; automatic candidates use generation-guarded CAS.
//! Linux flock on a fresh root-directory open description serializes cooperating
//! Stores across threads and processes, without creating a lock file. Locks are
//! held only for disk transactions. Caller frees Entry.content and Entry.version.
//! 中文：项目内 memory 存储于 .thin/memory。写入采用基于内容哈希版本的 CAS：版本不符返回 VersionConflict，
//! 调用方必须重新读取后再决定，不得盲目覆盖。文件权限固定为 0600，目录为 0700。

const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const config = @import("../core/config.zig");

const Root = fs.Root;
extern "c" fn fsync(c_int) c_int;
pub const directory_name = "memory";
pub const jobs_name = "jobs";
pub const owner_name = "jobs-owner";

fn exists(parent: c_int, name: [*:0]const u8) !bool {
    const fd = fs.linux.openat(parent, name, fs.linux.path_only | fs.linux.nofollow | fs.linux.cloexec, 0);
    if (fd >= 0) {
        fs.closeFd(fd);
        return true;
    }
    if (std.c._errno().* == 2) return false;
    return fs.osError();
}

fn lockOwner(parent: c_int, name: [*:0]const u8, io: std.Io) !c_int {
    const fd = fs.linux.openat(parent, name, 2 | fs.linux.create | fs.linux.nofollow | fs.linux.cloexec | fs.linux.nonblock, 0o600);
    if (fd < 0) return fs.osError();
    errdefer fs.closeFd(fd);
    if ((try fs.fileFromFd(fd).stat(io)).kind != .file) return error.NotRegularFile;
    while (fs.linux.flock(fd, 2 | 4) != 0) {
        const e = std.c._errno().*;
        if (e == 4) continue;
        if (e == 11) return error.Busy;
        return fs.osError();
    }
    return fd;
}

fn legacyOwnerNeedsMigration(thin: c_int, io: std.Io) !bool {
    const fd = fs.linux.openat(thin, "mem-jobs-owner", fs.linux.path_only | fs.linux.nofollow | fs.linux.cloexec, 0);
    if (fd < 0) {
        if (std.c._errno().* == 2) return false;
        return fs.osError();
    }
    defer fs.closeFd(fd);
    // A completed migration leaves a symlink tombstone. Old binaries use
    // O_NOFOLLOW and therefore cannot recreate a second lease/queue namespace.
    return (try fs.fileFromFd(fd).stat(io)).kind != .sym_link;
}

fn hasLegacyLayout(thin: c_int, io: std.Io) !bool {
    return try exists(thin, "mem") or try exists(thin, "mem-jobs") or try legacyOwnerNeedsMigration(thin, io);
}

/// One-time, no-merge migration from the original public layout. The durable
/// outbox is moved, never discarded: queued work and failed/uncertain replay
/// decisions remain authoritative. Both old and new worker lease inodes are
/// locked before any rename, so a live worker or mixed destination fails closed.
pub fn migrateLayout(root: *Root) !void {
    // Normal startup has no legacy artifacts and must not contend on the
    // optional Memory root lock merely to prove that migration is unnecessary.
    const probe = fs.openDirectory(root.dir.handle, ".thin") catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer fs.closeFd(probe);
    const migration_needed = try hasLegacyLayout(probe, root.io);
    if (!migration_needed) return;

    const locked = try fs.openDirectory(root.dir.handle, ".");
    defer fs.closeFd(locked);
    while (fs.linux.flock(locked, 2 | 4) != 0) {
        const e = std.c._errno().*;
        if (e == 4) continue;
        if (e == 11) return error.Busy;
        return fs.osError();
    }
    const thin = try fs.openDirectory(root.dir.handle, ".thin");
    defer fs.closeFd(thin);
    if (!try hasLegacyLayout(thin, root.io)) return;

    const old_memory = try exists(thin, "mem");
    const new_memory = try exists(thin, directory_name);
    if (old_memory and new_memory) return error.MemoryLayoutConflict;
    const old_jobs = try exists(thin, "mem-jobs");

    // Creating and locking the legacy owner closes the check/create race with
    // an old worker. Its inode has no durable payload; the queue directory is
    // the durable state that must be renamed intact.
    const legacy_owner = try lockOwner(thin, "mem-jobs-owner", root.io);
    defer fs.closeFd(legacy_owner);

    // If the store itself is legacy, establish the future destination lease
    // inside it before the directory becomes visible under the new name.
    const memory = if (old_memory)
        try child(thin, "mem", false)
    else
        try child(thin, directory_name, true);
    defer fs.closeFd(memory);
    const destination_owner = try lockOwner(memory, owner_name, root.io);
    defer fs.closeFd(destination_owner);

    if (old_jobs and try exists(memory, jobs_name)) return error.MemoryLayoutConflict;
    if (old_memory) {
        if (std.c.renameat(thin, "mem", thin, directory_name) != 0) return fs.osError();
        if (fsync(thin) != 0) return fs.osError();
    }
    if (old_jobs) {
        if (std.c.renameat(thin, "mem-jobs", memory, jobs_name) != 0) return fs.osError();
        if (fsync(memory) != 0 or fsync(thin) != 0) return fs.osError();
    }
    // Atomically replace the old lease pathname with an O_NOFOLLOW tombstone.
    // There is no unlink window in which a retrying legacy worker can create a
    // fresh inode and run alongside the new worker.
    const tombstone = ".mem-jobs-owner-tombstone";
    if (std.c.symlinkat("memory/jobs-owner", thin, tombstone) != 0) {
        if (std.c._errno().* != 17) return fs.osError();
        if (std.c.unlinkat(thin, tombstone, 0) != 0) return fs.osError();
        if (std.c.symlinkat("memory/jobs-owner", thin, tombstone) != 0) return fs.osError();
    }
    errdefer _ = std.c.unlinkat(thin, tombstone, 0);
    if (std.c.renameat(thin, tombstone, thin, "mem-jobs-owner") != 0) return fs.osError();
    if (fsync(memory) != 0 or fsync(thin) != 0) return fs.osError();
}
/// 一次读取的结果：content 为正文，version 为正文的 sha256 十六进制串（用作 CAS 比较依据）。
pub const Entry = struct { content: []const u8, version: []const u8 };

/// 项目 memory 的存储句柄；多个 Store 可共享同一 Root，互斥由 flock 保证。
pub const Store = struct {
    /// 项目根目录（不是 .thin/memory 本身）。
    root: *Root,
    /// core 与分片的大小、索引总预算等上限。
    limits: config.Limits,
    /// Optional reference reads may decline contention; manual operations wait.
    wait_for_lock: bool = true,

    /// 创建 Store；本身不做任何磁盘操作。
    pub fn init(root: *Root, limits: config.Limits) Store {
        return .{ .root = root, .limits = limits };
    }

    /// 获取跨线程、跨进程的独占锁。每次都重新 open 根目录得到新的 open description，
    /// 使同一进程内的多个 Store 之间 flock 也能互斥。返回的 fd 需由调用方关闭。
    fn lock(self: *Store) !c_int {
        const fd = try fs.openDirectory(self.root.dir.handle, ".");
        errdefer fs.closeFd(fd);

        // 2 = LOCK_EX，4 = LOCK_NB：非阻塞尝试；EINTR 直接重试，EWOULDBLOCK(11) 时 sleep 2ms 后再试。
        while (fs.linux.flock(fd, 2 | 4) != 0) {
            const e = std.c._errno().*;
            if (!self.wait_for_lock and (e == 4 or e == 11)) return error.Busy;
            if (e == 4) continue;
            if (e != 11) return fs.osError();
            try std.Io.sleep(self.root.io, .fromMilliseconds(2), .awake);
        }
        return fd;
    }

    /// 打开 .thin/memory 并返回新的 Root（调用方负责 deinit）。create 为 true 时才创建缺失目录；读路径从不创建路径。
    fn directory(self: *Store, create: bool) !Root {
        const thin = try child(self.root.dir.handle, ".thin", create);
        defer fs.closeFd(thin);

        const memory = try child(thin, directory_name, create);
        // memory 句柄由返回的 Root 持有；只有在后续失败时才由 errdefer 关闭。
        errdefer fs.closeFd(memory);
        return .{
            .dir = .{ .handle = memory },
            .io = self.root.io,
            .allocator = self.root.allocator,
            .path = try std.fs.path.join(self.root.allocator, &.{ self.root.path, ".thin", directory_name }),
        };
    }

    /// 检查文件大小是否超出 core 或分片的上限（core 与分片使用不同配额）。
    fn bound(self: *Store, topic: []const u8, size: u64) !void {
        if (std.mem.eql(u8, topic, "core")) {
            if (size > self.limits.core_bytes) return error.CoreTooLarge;
        } else if (size > self.limits.shard_bytes) return error.ShardTooLarge;
    }

    /// 读取 topic 正文并计算版本；返回的 content 与 version 都由 a 分配，调用方释放。
    fn load(self: *Store, mem: *Root, a: std.mem.Allocator, topic: []const u8) !Entry {
        const name = try filename(a, topic);
        defer a.free(name);
        const max = if (std.mem.eql(u8, topic, "core")) self.limits.core_bytes else self.limits.shard_bytes;
        const r = try mem.read(a, name, 0, max);
        errdefer a.free(r.data);

        // 先按真实大小校验；若读取被截断却仍通过校验，说明读取期间文件被改动，返回 FileChanged。
        try self.bound(topic, r.total_bytes);
        if (r.truncated) return error.FileChanged;
        return .{ .content = r.data, .version = try version(a, r.data) };
    }

    /// 在锁内读取 topic。topic 先于加锁校验；返回的 Entry 由 allocator 分配，调用方释放。
    pub fn read(self: *Store, allocator: std.mem.Allocator, topic: []const u8) !Entry {
        try validTopic(topic);
        const fd = try self.lock();
        defer fs.closeFd(fd);
        var mem = try self.directory(false);
        defer mem.deinit();
        return self.load(&mem, allocator, topic);
    }

    /// 带 CAS 的写入。expected_version 为 null 表示只允许创建；非空则必须与当前版本一致。
    /// 成功时返回新内容与其版本，均由 allocator 分配。
    pub fn write(self: *Store, allocator: std.mem.Allocator, topic: []const u8, content: []const u8, expected_version: ?[]const u8) !Entry {
        return self.writeImpl(allocator, topic, content, expected_version, null);
    }

    pub fn writeGuarded(self: *Store, allocator: std.mem.Allocator, topic: []const u8, content: []const u8, expected_version: ?[]const u8, expected_generation: u64) !Entry {
        return self.writeImpl(allocator, topic, content, expected_version, expected_generation);
    }

    fn writeImpl(self: *Store, allocator: std.mem.Allocator, topic: []const u8, content: []const u8, expected_version: ?[]const u8, guard: ?u64) !Entry {
        try validTopic(topic);
        try self.bound(topic, content.len);
        try fs.validateText(content);
        // Reserve all result allocations before committing a filesystem change.
        const owned_content = try allocator.dupe(u8, content);
        errdefer allocator.free(owned_content);
        const owned_version = try version(allocator, content);
        errdefer allocator.free(owned_version);
        const result: Entry = .{ .content = owned_content, .version = owned_version };

        // 从加锁开始到落盘结束是一个临界区，保证 CAS 检查与写入之间没有其他写者插入。
        const fd = try self.lock();
        defer fs.closeFd(fd);

        if (guard) |g| if (try self.generationUnlocked() != g) return error.GenerationConflict;

        // 只有创建时才允许建立目录；更新时若目录不存在，等价于版本冲突。
        var mem = self.directory(expected_version == null) catch |err| {
            if (err == error.FileNotFound and expected_version != null) return error.VersionConflict;
            return err;
        };
        defer mem.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // 当前文件不存在时 current 为 null，用来区分“创建”与“更新”。
        const current = self.load(&mem, a, topic) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

        // CAS：更新时版本必须一致；创建时若文件已存在则拒绝覆盖。
        if (expected_version) |expected| {
            if (current == null or !std.mem.eql(u8, current.?.version, expected)) return error.VersionConflict;
        } else if (current != null) return error.PathAlreadyExists;

        // Index budget is independent, and checked before publishing this write.
        // 索引预算先于落盘检查，避免写入成功后索引超限、留下不一致的状态。
        _ = try self.index(&mem, a, topic, content);
        const name = try filename(a, topic);
        // 最后一步才落盘；仅更新时允许覆盖已有文件，权限固定 0600 以保护私有记忆。
        if (guard == null) try self.advanceGeneration(&mem);
        try mem.writeMode(name, content, expected_version != null, 0o600);
        const written = fs.linux.openat(mem.dir.handle, name, fs.linux.nofollow | fs.linux.cloexec, 0);
        if (written < 0) return fs.osError();
        defer fs.closeFd(written);
        if (fsync(written) != 0 or fsync(mem.dir.handle) != 0) return fs.osError();
        return result;
    }

    /// 按版本删除 topic（CAS）。文件不存在或版本不一致都返回 VersionConflict。
    pub fn delete(self: *Store, topic: []const u8, expected_version: []const u8) !void {
        try validTopic(topic);
        const fd = try self.lock();
        defer fs.closeFd(fd);
        var mem = self.directory(false) catch |err| {
            if (err == error.FileNotFound) return error.VersionConflict;
            return err;
        };
        defer mem.deinit();

        var arena = std.heap.ArenaAllocator.init(self.root.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const current = self.load(&mem, a, topic) catch |err| {
            if (err == error.FileNotFound) return error.VersionConflict;
            return err;
        };

        if (!std.mem.eql(u8, current.version, expected_version)) return error.VersionConflict;
        const name = try filename(a, topic);

        try self.advanceGeneration(&mem);
        // 通过父目录句柄加文件名删除，而不是重新解析完整路径，减少路径竞争面。
        var p = try mem.parent(name);
        defer p.deinit();
        if (std.c.unlinkat(p.fd, p.name, 0) != 0) return fs.osError();
        if (fsync(p.fd) != 0) return fs.osError();
    }

    pub fn generation(self: *Store) !u64 {
        const fd = try self.lock();
        defer fs.closeFd(fd);
        return self.generationUnlocked();
    }

    /// Shared outbox transaction boundary. Caller MUST already hold the fresh
    /// project-root flock (the same lock as write/delete); never re-enter lock().
    pub fn generationLocked(self: *Store) !u64 {
        return self.generationUnlocked();
    }

    fn generationUnlocked(self: *Store) !u64 {
        var dir = self.directory(false) catch |err| {
            if (err == error.FileNotFound) return 0;
            return err;
        };
        defer dir.deinit();
        const bytes = dir.readBinary(self.root.allocator, ".generation", 20) catch |err| {
            if (err == error.FileNotFound) return 0;
            return err;
        };
        defer self.root.allocator.free(bytes);
        if (bytes.len == 0) return error.InvalidGeneration;
        for (bytes) |c| if (c < '0' or c > '9') return error.InvalidGeneration;
        return std.fmt.parseInt(u64, bytes, 10) catch error.InvalidGeneration;
    }

    fn advanceGeneration(self: *Store, dir: *Root) !void {
        const previous = try self.generationUnlocked();
        const next = std.math.add(u64, previous, 1) catch return error.GenerationOverflow;
        var buffer: [20]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d}", .{next});
        try dir.writeMode(".generation", text, true, 0o600);
        const fd = fs.linux.openat(dir.dir.handle, ".generation", fs.linux.nofollow | fs.linux.cloexec, 0);
        if (fd < 0) return fs.osError();
        defer fs.closeFd(fd);
        if (fsync(fd) != 0 or fsync(dir.dir.handle) != 0) return fs.osError();
        // Manual mutation invalidates every old-generation extraction. Forget
        // its queued/failed/uncertain plaintext too, even while Auto is Off.
        // The project flock is ALREADY held; do not re-enter Queue's lock.
        try self.clearOutboxSources();
    }

    fn clearOutboxSources(self: *Store) !void {
        const thin = try fs.openDirectory(self.root.dir.handle, ".thin");
        defer fs.closeFd(thin);
        const memory = fs.openDirectory(thin, directory_name) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer fs.closeFd(memory);
        const jobs = fs.openDirectory(memory, jobs_name) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer fs.closeFd(jobs);
        var iterator = (std.Io.Dir{ .handle = jobs }).iterate();
        var count: usize = 0;
        while (try iterator.next(self.root.io)) |item| {
            count += 1;
            if (count > 128) return error.InvalidJobStorage;
            var owned_job = item.name.len == 69 and std.mem.endsWith(u8, item.name, ".json");
            if (owned_job) for (item.name[0..64]) |byte| {
                if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) {
                    owned_job = false;
                    break;
                }
            };
            if (!owned_job and !std.mem.startsWith(u8, item.name, ".thin-tmp-")) return error.InvalidJobStorage;
            if (item.name.len > 255) return error.InvalidJobStorage;
            var name: [256:0]u8 = undefined;
            @memcpy(name[0..item.name.len], item.name);
            name[item.name.len] = 0;
            if (std.c.unlinkat(jobs, @ptrCast(&name), 0) != 0) return fs.osError();
        }
        if (fsync(jobs) != 0) return fs.osError();
    }

    pub fn coreSnapshot(self: *Store, a: std.mem.Allocator) ![]u8 {
        const entry = self.read(a, "core") catch |err| {
            if (err == error.FileNotFound) return a.dupe(u8, "");
            return err;
        };
        a.free(entry.version);
        return @constCast(entry.content);
    }

    pub fn topics(self: *Store, a: std.mem.Allocator) ![]const []const u8 {
        const fd = try self.lock();
        defer fs.closeFd(fd);
        var dir = self.directory(false) catch |err| {
            if (err == error.FileNotFound) return a.alloc([]const u8, 0);
            return err;
        };
        defer dir.deinit();
        var rows: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (rows.items) |row| a.free(row);
            rows.deinit(a);
        }
        var bytes: usize = 0;
        var it = dir.dir.iterate();
        while (try it.next(dir.io)) |item| {
            if (!std.mem.endsWith(u8, item.name, ".md")) continue;
            const topic = item.name[0 .. item.name.len - 3];
            try validTopic(topic);
            bytes += topic.len + 6;
            if (bytes > self.limits.index_bytes) return error.IndexTooLarge;
            try rows.append(a, try a.dupe(u8, topic));
        }
        std.mem.sort([]const u8, rows.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        return rows.toOwnedSlice(a);
    }

    /// Bounded titles only, for per-turn candidate selection (not permanent injection).
    pub fn topicIndex(self: *Store, a: std.mem.Allocator) ![]const u8 {
        const fd = try self.lock();
        defer fs.closeFd(fd);
        var dir = self.directory(false) catch |err| {
            if (err == error.FileNotFound) return a.dupe(u8, "");
            return err;
        };
        defer dir.deinit();
        return self.index(&dir, a, null, null);
    }

    /// Frozen by Runtime at startup. Missing storage creates no paths.
    /// Format: raw core followed by a sorted `filename: first line` shard index.
    /// 中文：返回启动时注入上下文的快照；core 缺失是正常情况，其他错误必须上报。
    pub fn snapshot(self: *Store, allocator: std.mem.Allocator) ![]const u8 {
        const fd = try self.lock();
        defer fs.closeFd(fd);
        var mem = self.directory(false) catch |err| {
            if (err == error.FileNotFound) return allocator.dupe(u8, "");
            return err;
        };
        defer mem.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const core = self.load(&mem, a, "core") catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

        // 索引只包含分片首行，不读取分片正文，使启动上下文大小保持可控。
        const idx = try self.index(&mem, a, null, null);

        if (idx.len == 0) return allocator.dupe(u8, if (core) |c| c.content else "");
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ if (core) |c| c.content else "", if (core != null and core.?.content.len > 0) "\n\n" else "", idx });
    }

    /// 生成排序后的索引文本（每行 "topic.md: 首行"）。replacement 为即将写入的 topic，其旧行被跳过，改用 content 生成的新行。
    fn index(self: *Store, mem: *Root, a: std.mem.Allocator, replacement: ?[]const u8, content: ?[]const u8) ![]const u8 {
        var rows: std.ArrayList([]const u8) = .empty;
        var bytes: usize = 0;

        var iterator = mem.dir.iterate();
        while (try iterator.next(mem.io)) |item| {
            if (!std.mem.endsWith(u8, item.name, ".md")) continue;
            const topic = item.name[0 .. item.name.len - 3];
            try validTopic(topic);
            if (std.mem.eql(u8, topic, "core")) continue;

            // 被替换的 topic 旧行跳过，避免索引中出现重复行。
            if (replacement) |r| if (std.mem.eql(u8, r, topic)) continue;

            // 6 = ".md: " 的 5 字节加换行，用于在读取前提前检查索引预算。
            const overhead = topic.len + 6;
            if (overhead > self.limits.index_bytes or bytes > self.limits.index_bytes - overhead) return error.IndexTooLarge;

            // Index only the first line, not every complete shard and hash.
            // Reclaim each read before advancing; memory is bounded by index
            // size plus one title, rather than topic-count times shard size.
            var temporary = std.heap.ArenaAllocator.init(self.root.allocator);
            defer temporary.deinit();
            const title = try self.firstLine(mem, temporary.allocator(), topic, self.limits.index_bytes - bytes - overhead);
            try self.addRow(a, &rows, &bytes, topic, title);
        }

        // 待写入的新 topic 不一定已在目录中，因此单独加入索引；core 从不进入索引。
        if (replacement) |r| if (!std.mem.eql(u8, r, "core")) try self.addRow(a, &rows, &bytes, r, content.?);

        // 排序使输出与文件系统遍历顺序无关，结果稳定、可比较。
        std.mem.sort([]const u8, rows.items, {}, struct {
            fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.less);
        return std.mem.join(a, "", rows.items);
    }

    /// 只读取分片首行，最多 limit 字节。以 O_NOFOLLOW|O_NONBLOCK 打开，拒绝符号链接与非普通文件。
    fn firstLine(self: *Store, mem: *Root, a: std.mem.Allocator, topic: []const u8, limit: usize) ![]const u8 {
        const name = try filename(a, topic);
        var parent = try mem.parent(name);
        defer parent.deinit();

        // nofollow 防止经符号链接读到项目外文件；nonblock 防止 FIFO 之类的特殊文件阻塞线程。
        const fd = fs.linux.openat(parent.fd, parent.name, fs.linux.nofollow | fs.linux.cloexec | fs.linux.nonblock, 0);
        if (fd < 0) return fs.osError();
        defer fs.closeFd(fd);

        const file = fs.fileFromFd(fd);
        const stat = try file.stat(mem.io);
        if (stat.kind != .file) return error.NotRegularFile;
        try self.bound(topic, stat.size);

        var line: std.ArrayList(u8) = .empty;
        var offset: u64 = 0;
        var buffer: [512]u8 = undefined;
        while (offset < stat.size) {
            // 每次读取的上限是剩余预算加 1：多读 1 字节即可判断首行是否超限。
            const count: usize = @intCast(@min(@as(u64, buffer.len), @min(stat.size - offset, limit - line.items.len + 1)));
            const n = try file.readPositionalAll(mem.io, buffer[0..count], offset);
            if (n != count) return error.FileChanged;
            const newline = std.mem.findScalar(u8, buffer[0..n], '\n');
            const end = newline orelse n;
            // 首行超过预算时直接报错，而不是截断后静默写入索引。
            if (end > limit - line.items.len) return error.IndexTooLarge;
            try line.appendSlice(a, buffer[0..end]);
            if (newline != null) break;
            offset += n;
        }

        // 首行必须是合法文本，否则索引会带入二进制内容。
        try fs.validateText(line.items);
        return line.items;
    }

    /// 追加一行索引并累计字节数；超出 index_bytes 预算时返回 IndexTooLarge。
    fn addRow(self: *Store, a: std.mem.Allocator, rows: *std.ArrayList([]const u8), bytes: *usize, topic: []const u8, content: []const u8) !void {
        // 只取第一行作为标题。
        const line = content[0..(std.mem.findScalar(u8, content, '\n') orelse content.len)];
        const len = topic.len + 6 + line.len; // `.md: ` + newline
        if (len > self.limits.index_bytes or bytes.* > self.limits.index_bytes - len) return error.IndexTooLarge;
        bytes.* += len;
        try rows.append(a, try std.fmt.allocPrint(a, "{s}.md: {s}\n", .{ topic, line }));
    }
};

/// 在 parent 下打开子目录；create 为 true 且目录不存在时以 0700 创建。
fn child(parent: c_int, name: [*:0]const u8, create: bool) !c_int {
    return fs.openDirectory(parent, name) catch |err| {
        if (err != error.FileNotFound or !create) return err;
        // 17 = EEXIST：并发创建时目录已存在，视为成功。
        if (std.c.mkdirat(parent, name, 0o700) != 0 and std.c._errno().* != 17) return fs.osError();
        if (fsync(parent) != 0) return fs.osError();
        return fs.openDirectory(parent, name);
    };
}

/// 校验 topic：1-64 字节，只允许小写字母、数字，以及非首位的 '-'，从而杜绝路径注入。
pub fn validTopic(topic: []const u8) !void {
    if (topic.len == 0 or topic.len > 64) return error.InvalidTopic;
    for (topic, 0..) |c, i| {
        if (!(c >= 'a' and c <= 'z') and !(c >= '0' and c <= '9') and !(i != 0 and c == '-')) return error.InvalidTopic;
    }
}

/// 生成 "topic.md" 形式的文件名，带 0 结尾以便传给 C 系统调用。
fn filename(a: std.mem.Allocator, topic: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(a, "{s}.md", .{topic}, 0);
}

/// 内容版本：sha256 的小写十六进制串，作为 CAS 的比较依据。
/// 纯计算且返回拥有型字符串；工具可在提交前预构造成功结果。
pub fn version(a: std.mem.Allocator, content: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return a.dupe(u8, &hex);
}

/// 释放 Entry 中由 a 分配的 content 与 version。
fn freeEntry(a: std.mem.Allocator, entry: Entry) void {
    a.free(entry.content);
    a.free(entry.version);
}

/// 测试辅助：通过 realPath 取得临时目录的绝对路径，并据此创建 Root。
fn testRoot(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Root {
    var buffer: [4096]u8 = undefined;
    const n = try dir.realPath(io, &buffer);
    return Root.open(a, io, buffer[0..n]);
}

test "memory layout migration preserves shards jobs and owner without merging" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(root.dir.handle, ".thin", 0o700));
    const thin = try fs.openDirectory(root.dir.handle, ".thin");
    defer fs.closeFd(thin);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(thin, "mem", 0o700));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(thin, "mem-jobs", 0o700));
    try root.writeMode(".thin/mem/core.md", "legacy core", false, 0o600);
    try root.writeMode(".thin/mem-jobs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json", "legacy job", false, 0o600);
    const owner = fs.linux.openat(thin, "mem-jobs-owner", 2 | fs.linux.create | fs.linux.exclusive | fs.linux.nofollow | fs.linux.cloexec, 0o600);
    try std.testing.expect(owner >= 0);
    fs.closeFd(owner);

    try migrateLayout(&root);
    try migrateLayout(&root); // completed migrations are idempotent.
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(thin, "mem"));
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(thin, "mem-jobs"));
    const core = try root.readBinary(a, ".thin/memory/core.md", 1024);
    defer a.free(core);
    try std.testing.expectEqualStrings("legacy core", core);
    const job = try root.readBinary(a, ".thin/memory/jobs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json", 1024);
    defer a.free(job);
    try std.testing.expectEqualStrings("legacy job", job);
    const migrated_owner = fs.linux.openat(thin, "memory/jobs-owner", fs.linux.nofollow | fs.linux.cloexec, 0);
    try std.testing.expect(migrated_owner >= 0);
    fs.closeFd(migrated_owner);
    const legacy_tombstone = try fs.openPath(thin, "mem-jobs-owner");
    defer fs.closeFd(legacy_tombstone);
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, (try fs.fileFromFd(legacy_tombstone).stat(io)).kind);

    var conflict_tmp = std.testing.tmpDir(.{});
    defer conflict_tmp.cleanup();
    var conflict_root = try testRoot(a, io, conflict_tmp.dir);
    defer conflict_root.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(conflict_root.dir.handle, ".thin", 0o700));
    const conflict_thin = try fs.openDirectory(conflict_root.dir.handle, ".thin");
    defer fs.closeFd(conflict_thin);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(conflict_thin, "mem", 0o700));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(conflict_thin, directory_name, 0o700));
    try std.testing.expectError(error.MemoryLayoutConflict, migrateLayout(&conflict_root));

    var busy_tmp = std.testing.tmpDir(.{});
    defer busy_tmp.cleanup();
    var busy_root = try testRoot(a, io, busy_tmp.dir);
    defer busy_root.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(busy_root.dir.handle, ".thin", 0o700));
    const busy_thin = try fs.openDirectory(busy_root.dir.handle, ".thin");
    defer fs.closeFd(busy_thin);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(busy_thin, directory_name, 0o700));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(busy_thin, "mem-jobs", 0o700));
    const busy_memory = try fs.openDirectory(busy_thin, directory_name);
    defer fs.closeFd(busy_memory);
    const busy_owner = try lockOwner(busy_memory, owner_name, io);
    defer fs.closeFd(busy_owner);
    try std.testing.expectError(error.Busy, migrateLayout(&busy_root));
    const unmoved = try fs.openDirectory(busy_thin, "mem-jobs");
    fs.closeFd(unmoved);
}

// 空存储的 snapshot 不产生任何副作用；两个 Store 之间的 CAS 语义正确。
test "memory empty snapshot has no side effects and CAS updates across Stores" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    var one = Store.init(&root, .{});
    var two = Store.init(&root, .{});
    const empty = try one.snapshot(a);
    defer a.free(empty);
    try std.testing.expectEqualStrings("", empty);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    try std.testing.expectError(error.FileNotFound, one.read(a, "missing"));

    const first = try one.write(a, "topic", "first", null);
    defer freeEntry(a, first);
    try std.testing.expectError(error.PathAlreadyExists, two.write(a, "topic", "lost", null));
    const second = try two.write(a, "topic", "second", first.version);
    defer freeEntry(a, second);
    try std.testing.expectError(error.VersionConflict, one.write(a, "topic", "lost", first.version));
    try std.testing.expectError(error.VersionConflict, one.delete("topic", first.version));

    const latest = try one.read(a, "topic");
    defer freeEntry(a, latest);
    try std.testing.expectEqualStrings("second", latest.content);
    try one.delete("topic", second.version);
    try std.testing.expectError(error.FileNotFound, two.read(a, "topic"));
    try std.testing.expectError(error.InvalidTopic, one.read(a, "../x"));

    const stat = try root.dir.statFile(io, ".thin/memory", .{});
    try std.testing.expectEqual(@as(u32, 0o700), stat.permissions.toMode() & 0o777);
}

/// 以 expected 为版本尝试写入：成功返回 true，VersionConflict 返回 false，其他错误原样抛出。
fn competingWrite(store: *Store, expected: []const u8, text: []const u8) !bool {
    const a = std.heap.page_allocator;
    const result = store.write(a, "topic", text, expected) catch |err| {
        if (err == error.VersionConflict) return false;
        return err;
    };
    defer freeEntry(a, result);
    return true;
}

/// 测试用 libc 声明：fork 与 waitpid 用于验证跨进程的 flock 互斥。
extern "c" fn fork() c_int;
/// 等待子进程结束。
extern "c" fn waitpid(c_int, *c_int, c_int) c_int;
/// 子进程中使用 _exit 而非 exit，避免执行继承自父进程的退出处理。
extern "c" fn _exit(c_int) noreturn;

// 验证两个线程 Store 只有一方写入成功，并且另一进程无法获取已持有的 flock。
test "memory real concurrent Stores and cross-process flock exclusion" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{ .concurrent_limit = .limited(4) });
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    var one = Store.init(&root, .{});
    var two = Store.init(&root, .{});
    const initial = try one.write(a, "topic", "initial", null);
    defer freeEntry(a, initial);

    var first = try std.Io.concurrent(io, competingWrite, .{ &one, initial.version, "first" });
    defer _ = first.cancel(io) catch {};
    var second = try std.Io.concurrent(io, competingWrite, .{ &two, initial.version, "second" });
    defer _ = second.cancel(io) catch {};
    const first_won = try first.await(io);
    const second_won = try second.await(io);
    try std.testing.expect(first_won != second_won);

    const held = try one.lock();
    defer fs.closeFd(held);

    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Only async-signal-safe libc operations after fork in the threaded process.
        // 中文：多线程进程 fork 后，子进程只能调用 async-signal-safe 的操作。
        fs.closeFd(held);
        // 子进程独立 open 根目录，得到新的 open description，flock 应返回 EWOULDBLOCK(11)，证明互斥生效。
        const independent = fs.linux.openat(root.dir.handle, ".", fs.linux.directory | fs.linux.cloexec, 0);
        if (independent < 0) _exit(2);
        const rc = fs.linux.flock(independent, 2 | 4);
        const excluded = rc == -1 and std.c._errno().* == 11;
        fs.closeFd(independent);
        _exit(if (excluded) 0 else 3);
    }

    var status: c_int = 0;
    var waited: c_int = undefined;
    while (true) {
        waited = waitpid(pid, &status, 0);
        if (waited < 0 and std.c._errno().* == 4) continue;
        break;
    }
    try std.testing.expectEqual(pid, waited);
    try std.testing.expectEqual(@as(c_int, 0), status);
}

// 符号链接形式的 .thin 与分片都必须被拒绝（分别返回 NotDir 与 SymlinkNotAllowed）。
test "memory refuses symlink directories and shards" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, backend.io(), tmp.dir);
    defer root.deinit();
    var store = Store.init(&root, .{});
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("/", root.dir.handle, ".thin"));
    try std.testing.expectError(error.NotDir, store.snapshot(a));
    try std.testing.expectError(error.NotDir, store.write(a, "core", "text", null));
    try std.testing.expectEqual(@as(c_int, 0), std.c.unlinkat(root.dir.handle, ".thin", 0));

    const c = try store.write(a, "core", "core", null);
    defer freeEntry(a, c);

    var mem = try store.directory(false);
    defer mem.deinit();
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("/not-read", mem.dir.handle, "escape.md"));
    try std.testing.expectError(error.SymlinkNotAllowed, store.read(a, "escape"));
    try std.testing.expectError(error.SymlinkNotAllowed, store.snapshot(a));
}

// 索引只读取分片首行，不把正文加载进上下文；超出分片上限时报 ShardTooLarge。
test "index reads bounded titles, not full shard bodies" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    var store = Store.init(&root, .{});
    const initial = try store.write(a, "topic", "Title\nbody", null);
    defer freeEntry(a, initial);

    // A separately edited body is checked by read, not secretly loaded into
    // startup context merely to obtain its first line.
    const binary_body: [20000]u8 = @splat(0);
    try tmp.dir.writeFile(io, .{ .sub_path = ".thin/memory/topic.md", .data = "Title\n" ++ binary_body });

    const snapshot = try store.snapshot(a);
    defer a.free(snapshot);
    try std.testing.expectEqualStrings("topic.md: Title\n", snapshot);
    try std.testing.expectError(error.BinaryFile, store.read(a, "topic"));

    store.limits.shard_bytes = 100;
    try std.testing.expectError(error.ShardTooLarge, store.snapshot(a));

    try std.testing.expectError(error.InvalidTopic, validTopic("-topic"));
    try std.testing.expectError(error.InvalidTopic, validTopic("a_b"));

    const long_topic: [65]u8 = @splat('a');
    try std.testing.expectError(error.InvalidTopic, validTopic(&long_topic));
}

// 索引排序稳定、各项预算（core、分片、索引总量）独立生效，且不同项目之间互相隔离。
test "memory sorted index independent limits and project isolation" {
    const a = std.testing.allocator;
    var backend = std.Io.Threaded.init(a, .{});
    defer backend.deinit();
    const io = backend.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var other = std.testing.tmpDir(.{});
    defer other.cleanup();
    var root = try testRoot(a, io, tmp.dir);
    defer root.deinit();
    var root2 = try testRoot(a, io, other.dir);
    defer root2.deinit();
    var store = Store.init(&root, .{ .core_bytes = 4, .index_bytes = 30, .shard_bytes = 12, .read_bytes = 1 });
    var isolated = Store.init(&root2, .{});

    const c = try store.write(a, "core", "CORE", null);
    defer freeEntry(a, c);
    const z = try store.write(a, "z", "zed\nrest", null);
    defer freeEntry(a, z);
    const aa = try store.write(a, "a", "alpha", null);
    defer freeEntry(a, aa);

    const snap = try store.snapshot(a);
    defer a.free(snap);
    try std.testing.expectEqualStrings("CORE\n\na.md: alpha\nz.md: zed\n", snap);
    try std.testing.expectError(error.FileNotFound, isolated.read(a, "core"));
    try std.testing.expectError(error.CoreTooLarge, store.write(a, "core", "large", c.version));
    try std.testing.expectError(error.ShardTooLarge, store.write(a, "shard", "1234567890123", null));
    try std.testing.expectError(error.IndexTooLarge, store.write(a, "extra", "123456789", null));
    try std.testing.expectError(error.FileNotFound, store.read(a, "extra"));

    const stat = try root.dir.statFile(io, ".thin/memory/core.md", .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);

    store.limits.index_bytes = 1;
    try std.testing.expectError(error.IndexTooLarge, store.snapshot(a));
    store.limits.index_bytes = 30;

    store.limits.core_bytes = 3;
    try std.testing.expectError(error.CoreTooLarge, store.snapshot(a));
    store.limits.core_bytes = 4;

    store.limits.shard_bytes = 2;
    try std.testing.expectError(error.ShardTooLarge, store.read(a, "a"));
}
