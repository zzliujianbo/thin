//! Shared explicit and evidence-grounded automatic project memory. Never a
//! conversation log; automatic candidates use generation-guarded CAS.
//! Linux flock on a fresh root-directory open description serializes cooperating
//! Stores across threads and processes, without creating a lock file. Locks are
//! held only for disk transactions. Caller frees Entry.content and Entry.version.
//! 中文：项目内 memory 存储于 .thin/memory。写入采用基于内容哈希版本的 CAS：版本不符返回 VersionConflict，
//! 调用方必须重新读取后再决定，不得盲目覆盖。文件权限固定为 0600，目录为 0700。

const std = @import("std");
const fs = @import("../platform/filesystem.zig");

const Root = fs.Root;
extern "c" fn fsync(c_int) c_int;
pub const directory_name = "memory";
/// The filesystem directory is the index. Titles are capped per row so one
/// entry can never make listing or retrieval unbounded.
pub const max_title_bytes: usize = 512;
pub const default_list_limit: usize = 100;
pub const max_list_limit: usize = 1000;

/// 一次读取的结果：content 为正文，version 为正文的 sha256 十六进制串（用作 CAS 比较依据）。
pub const Entry = struct { content: []const u8, version: []const u8 };

/// 项目 memory 的存储句柄；多个 Store 可共享同一 Root，互斥由 flock 保证。
pub const Store = struct {
    /// 项目根目录（不是 .thin/memory 本身）。
    root: *Root,
    /// Optional reference reads may decline contention; manual operations wait.
    wait_for_lock: bool = true,

    /// 创建 Store；本身不做任何磁盘操作。
    pub fn init(root: *Root) Store {
        return .{ .root = root };
    }

    /// 获取跨线程、跨进程的独占锁。每次都重新 open 根目录得到新的 open description，
    /// 使同一进程内的多个 Store 之间 flock 也能互斥。返回的 fd 需由调用方关闭。
    fn lock(self: *Store) !c_int {
        const fd = try fs.openDirectory(self.root.dir.handle, ".");
        errdefer fs.closeFd(fd);

        // 非阻塞尝试；EINTR 直接重试，EWOULDBLOCK 时 sleep 2ms 后再试。
        while (fs.flock(fd, fs.LOCK.EX | fs.LOCK.NB) != 0) {
            const e = fs.errno();
            if (!self.wait_for_lock and (e == .INTR or e == .AGAIN)) return error.Busy;
            if (e == .INTR) continue;
            if (e != .AGAIN) return fs.osError();
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

    /// 读取 topic 正文并计算版本；返回的 content 与 version 都由 a 分配，调用方释放。
    fn load(self: *Store, mem: *Root, a: std.mem.Allocator, topic: []const u8) !Entry {
        const name = try filename(a, topic);
        defer a.free(name);
        const fd = fs.openAt(mem.dir.handle, name, .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
        if (fd < 0) return fs.osError();
        defer fs.closeFd(fd);
        const file = fs.fileFromFd(fd);
        const stat = try file.stat(self.root.io);
        if (stat.kind != .file) return error.NotRegularFile;
        const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        const data = try a.alloc(u8, size);
        errdefer a.free(data);
        if (try file.readPositionalAll(self.root.io, data, 0) != size) return error.FileChanged;
        if ((try file.stat(self.root.io)).size != stat.size) return error.FileChanged;
        try fs.validateText(data);
        return .{ .content = data, .version = try version(a, data) };
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

        const name = try filename(a, topic);
        // 最后一步才落盘；仅更新时允许覆盖已有文件，权限固定 0600 以保护私有记忆。
        if (guard == null) try self.advanceGeneration(&mem);
        try mem.writeMode(name, content, expected_version != null, 0o600);
        const written = fs.openAt(mem.dir.handle, name, .{ .NOFOLLOW = true, .CLOEXEC = true }, 0);
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
        const fd = fs.openAt(dir.dir.handle, ".generation", .{ .NOFOLLOW = true, .CLOEXEC = true }, 0);
        if (fd < 0) return fs.osError();
        defer fs.closeFd(fd);
        if (fsync(fd) != 0 or fsync(dir.dir.handle) != 0) return fs.osError();
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
        var it = dir.dir.iterate();
        while (try it.next(dir.io)) |item| {
            if (!std.mem.endsWith(u8, item.name, ".md")) continue;
            const topic = item.name[0 .. item.name.len - 3];
            try validTopic(topic);
            try rows.append(a, try a.dupe(u8, topic));
        }
        std.mem.sort([]const u8, rows.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        return rows.toOwnedSlice(a);
    }

    /// Streaming visitor over topic name and bounded first-line title. The
    /// directory is the index: callers never receive a full index string. The
    /// callback runs under the store lock and must not call Store methods.
    pub const TopicVisitor = struct {
        context: ?*anyopaque = null,
        visit_fn: *const fn (?*anyopaque, []const u8, []const u8) anyerror!void,

        fn visit(self: TopicVisitor, topic: []const u8, title: []const u8) !void {
            return self.visit_fn(self.context, topic, title);
        }
    };

    pub fn forEachTopic(self: *Store, visitor: TopicVisitor) !void {
        const fd = try self.lock();
        defer fs.closeFd(fd);
        var dir = self.directory(false) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer dir.deinit();
        var it = dir.dir.iterate();
        while (try it.next(dir.io)) |item| {
            if (!std.mem.endsWith(u8, item.name, ".md")) continue;
            const topic = item.name[0 .. item.name.len - 3];
            if (std.mem.eql(u8, topic, "core")) continue;
            try validTopic(topic);
            {
                var temporary = std.heap.ArenaAllocator.init(self.root.allocator);
                defer temporary.deinit();
                const title = try self.firstLine(&dir, temporary.allocator(), topic);
                try visitor.visit(topic, title);
            }
        }
    }

    pub const ListPage = struct {
        total: usize,
        offset: usize,
        count: usize,
        text: []u8,
    };

    /// Sorted, paginated listing without a total byte budget. Only the selected
    /// page's first lines are read; the full index is never materialized.
    pub fn listPage(self: *Store, a: std.mem.Allocator, offset: usize, limit: usize) !ListPage {
        const fd = try self.lock();
        defer fs.closeFd(fd);
        var dir = self.directory(false) catch |err| {
            if (err == error.FileNotFound) return .{ .total = 0, .offset = 0, .count = 0, .text = try a.dupe(u8, "") };
            return err;
        };
        defer dir.deinit();

        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |name| a.free(name);
            names.deinit(a);
        }
        var it = dir.dir.iterate();
        while (try it.next(dir.io)) |item| {
            if (!std.mem.endsWith(u8, item.name, ".md")) continue;
            const topic = item.name[0 .. item.name.len - 3];
            if (std.mem.eql(u8, topic, "core")) continue;
            try validTopic(topic);
            try names.append(a, try a.dupe(u8, topic));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);

        const total = names.items.len;
        const start = @min(offset, total);
        const count = @min(limit, total - start);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        for (names.items[start .. start + count]) |topic| {
            var temporary = std.heap.ArenaAllocator.init(self.root.allocator);
            defer temporary.deinit();
            const title = try self.firstLine(&dir, temporary.allocator(), topic);
            const row = try std.fmt.allocPrint(a, "{s}.md: {s}\n", .{ topic, title });
            defer a.free(row);
            try out.appendSlice(a, row);
        }
        return .{ .total = total, .offset = start, .count = count, .text = try out.toOwnedSlice(a) };
    }

    /// Legacy full snapshot for callers/tests that need one string. Production
    /// listing uses listPage; writes never rebuild an index.
    pub fn snapshot(self: *Store, allocator: std.mem.Allocator) ![]const u8 {
        const core = try self.coreSnapshot(allocator);
        defer allocator.free(core);
        const page = try self.listPage(allocator, 0, std.math.maxInt(usize));
        defer allocator.free(page.text);
        if (page.text.len == 0) return allocator.dupe(u8, core);
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ core, if (core.len != 0) "\n\n" else "", page.text });
    }

    /// Read only the first line, capped at max_title_bytes. Truncation happens
    /// on a UTF-8 boundary; the complete body is never loaded for listing.
    fn firstLine(_: *Store, mem: *Root, a: std.mem.Allocator, topic: []const u8) ![]const u8 {
        const name = try filename(a, topic);
        defer a.free(name);
        var parent = try mem.parent(name);
        defer parent.deinit();

        // nofollow 防止经符号链接读到项目外文件；nonblock 防止 FIFO 之类的特殊文件阻塞线程。
        const fd = fs.openAt(parent.fd, parent.name, .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
        if (fd < 0) return fs.osError();
        defer fs.closeFd(fd);

        const file = fs.fileFromFd(fd);
        const stat = try file.stat(mem.io);
        if (stat.kind != .file) return error.NotRegularFile;

        const want: usize = @intCast(@min(stat.size, max_title_bytes));
        const line = try a.alloc(u8, want);
        defer a.free(line);
        if (want != 0) {
            const n = try file.readPositionalAll(mem.io, line, 0);
            if (n != want) return error.FileChanged;
        }
        var end = std.mem.findScalar(u8, line, '\n') orelse line.len;
        if (end == line.len and stat.size > line.len) {
            // The cap cut the first line; drop only an incomplete UTF-8 suffix.
            // Invalid bytes earlier in the line still make validateText fail.
            end = completeUtf8Prefix(line);
        }
        try fs.validateText(line[0..end]);
        return a.dupe(u8, line[0..end]);
    }
};

/// Return the prefix ending on a complete UTF-8 sequence. Only an incomplete
/// suffix is removed; invalid bytes elsewhere are left for validateText.
fn completeUtf8Prefix(bytes: []const u8) usize {
    var i = bytes.len;
    var continuation: usize = 0;
    while (i > 0) {
        const byte = bytes[i - 1];
        if (byte & 0xc0 == 0x80) {
            continuation += 1;
            if (continuation > 3) return bytes.len;
            i -= 1;
            continue;
        }
        const need: usize = if (byte & 0x80 == 0) 1 else if (byte & 0xe0 == 0xc0) 2 else if (byte & 0xf0 == 0xe0) 3 else if (byte & 0xf8 == 0xf0) 4 else return bytes.len;
        return if (continuation + 1 < need) i - 1 else bytes.len;
    }
    return bytes.len;
}

/// 在 parent 下打开子目录；create 为 true 且目录不存在时以 0700 创建。
fn child(parent: c_int, name: [*:0]const u8, create: bool) !c_int {
    return fs.openDirectory(parent, name) catch |err| {
        if (err != error.FileNotFound or !create) return err;
        // EEXIST：并发创建时目录已存在，视为成功。
        if (std.c.mkdirat(parent, name, 0o700) != 0 and fs.errno() != .EXIST) return fs.osError();
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

// 释放 Entry 中由 a 分配的 content 与 version。

// 测试辅助：通过 realPath 取得临时目录的绝对路径，并据此创建 Root。

// 空存储的 snapshot 不产生任何副作用；两个 Store 之间的 CAS 语义正确。

// 以 expected 为版本尝试写入：成功返回 true，VersionConflict 返回 false，其他错误原样抛出。

// 测试用 libc 声明：fork 与 waitpid 用于验证跨进程的 flock 互斥。

// 等待子进程结束。

// 子进程中使用 _exit 而非 exit，避免执行继承自父进程的退出处理。

// 验证两个线程 Store 只有一方写入成功，并且另一进程无法获取已持有的 flock。

// 符号链接形式的 .thin 与分片都必须被拒绝（分别返回 NotDir 与 SymlinkNotAllowed）。

// 索引只读取分片首行，不把正文加载进上下文；超出分片上限时报 ShardTooLarge。

// 排序稳定、core/分片预算独立生效，且不同项目之间互相隔离；legacy index_bytes 不限制总量。
