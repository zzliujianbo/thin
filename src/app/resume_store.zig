//! Bounded checkpoints with atomic publication and cooperative writer leases.
//! Reads ignore old markers/digests. Each complete read captures the next write's
//! CAS baseline. Read-only leases do not acquire writer locks, so an active
//! session remains viewable. Digests detect writes; they do not authenticate.
const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const logs = @import("log_store.zig");
const ids = @import("session_id.zig");
const Hash = std.crypto.hash.sha2.Sha256;

extern "c" fn fsync(c_int) c_int;

fn fsyncFd(fd: c_int) !void {
    while (true) {
        if (fsync(fd) == 0) return;
        if (fs.errno() == .INTR) continue; // EINTR
        return fs.osError();
    }
}

fn name(buffer: []u8, id: ids.Id, suffix: []const u8) ![:0]u8 {
    if (!ids.valid(id)) return error.InvalidSessionID;
    return std.fmt.bufPrintSentinel(buffer, "{s}{s}", .{ id, suffix }, 0);
}

fn readFile(root: *fs.Root, dir: c_int, id: ids.Id) !?[]u8 {
    var buffer: [64]u8 = undefined;
    const path = try name(&buffer, id, ".session");
    const fd = fs.openAt(dir, path, .{ .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
    if (fd < 0) return if (fs.errno() == .NOENT) null else fs.osError();
    defer fs.closeFd(fd);
    const file = fs.fileFromFd(fd);
    const stat = try file.stat(root.io);
    if (stat.kind != .file) return error.UnsafeResumeFile;
    if (stat.size == 0) return error.InvalidResumeLength;
    const size = std.math.cast(usize, stat.size) orelse return error.InvalidResumeLength;
    const bytes = try root.allocator.alloc(u8, std.math.add(usize, size, 1) catch return error.InvalidResumeLength);
    defer root.allocator.free(bytes);
    const n = try file.readPositionalAll(root.io, bytes, 0);
    if (n != stat.size) return error.FileChanged;
    return try root.allocator.dupe(u8, bytes[0..n]);
}

const session_metadata = @import("../core/session_metadata.zig");
pub const Summary = session_metadata.SavedSession;

fn readTitle(root: *fs.Root, dir: c_int, id: ids.Id) session_metadata.Title {
    var filename: [64]u8 = undefined;
    const path = name(&filename, id, ".title") catch return .{};
    const fd = fs.openAt(dir, path, .{ .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
    if (fd < 0) return .{};
    defer fs.closeFd(fd);
    const file = fs.fileFromFd(fd);
    const stat = file.stat(root.io) catch return .{};
    if (stat.kind != .file or stat.size == 0 or stat.size > 256) return .{};
    var bytes: [257]u8 = undefined;
    const n = file.readPositionalAll(root.io, &bytes, 0) catch return .{};
    if (n != stat.size) return .{};
    return session_metadata.Title.fromText(bytes[0..n]);
}

/// List checkpoint metadata in this project only. No checkpoint content is read,
/// and a missing namespace stays missing. Candidate metadata is inspected
/// relative to the validated directory without following final symlinks.
pub fn list(root: *fs.Root, allocator: std.mem.Allocator) ![]Summary {
    const fd = logs.openExistingDirectory(root) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(Summary, 0),
        else => return err,
    };
    defer fs.closeFd(fd);
    const dir: std.Io.Dir = .{ .handle = fd };
    var iterator = dir.iterate();
    var items: std.ArrayList(Summary) = .empty;
    errdefer items.deinit(allocator);
    while (try iterator.next(root.io)) |entry| {
        if (entry.name.len != 40 or !std.mem.endsWith(u8, entry.name, ".session")) continue;
        const id: ids.Id = entry.name[0..32].*;
        if (!ids.valid(id)) continue;
        const stat = dir.statFile(root.io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind != .file) continue;
        try items.append(allocator, .{ .id = id, .modified_ms = @intCast(stat.mtime.toMilliseconds()), .title = readTitle(root, fd, id) });
    }
    std.mem.sort(Summary, items.items, {}, struct {
        fn less(_: void, a: Summary, b: Summary) bool {
            if (a.modified_ms != b.modified_ms) return a.modified_ms > b.modified_ms;
            return std.mem.order(u8, &a.id, &b.id) == .lt;
        }
    }.less);
    return items.toOwnedSlice(allocator);
}

/// Fixed checkpoint names only. Do not relax the general file tool's UTF-8
/// contract just to store authenticated binary framing.
fn atomicWrite(root: *fs.Root, dir: c_int, path: [:0]const u8, bytes: []const u8, replace: bool) !void {
    var buffer: [80]u8 = undefined;
    var temp: [:0]u8 = undefined;
    var fd: c_int = -1;
    for (0..16) |_| {
        var random: [16]u8 = undefined;
        try root.io.randomSecure(&random);
        temp = try std.fmt.bufPrintSentinel(&buffer, ".resume-tmp-{s}", .{std.fmt.bytesToHex(random, .lower)}, 0);
        fd = fs.openAt(dir, temp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0o600);
        if (fd >= 0) break;
        if (fs.errno() != .EXIST) return fs.osError();
    }
    if (fd < 0) return error.TempNameExhausted;
    defer fs.closeFd(fd);
    defer _ = std.c.unlinkat(dir, temp, 0);
    try fs.fileFromFd(fd).writePositionalAll(root.io, bytes, 0);
    if (std.c.fchmod(fd, 0o600) != 0) return fs.osError();
    // Data must be durable before the directory entry publishes the name.
    try fsyncFd(fd);
    if (replace) {
        if (std.c.renameat(dir, temp, dir, path) != 0) return fs.osError();
    } else if (std.c.linkat(dir, temp, dir, path, 0) != 0) return fs.osError();
    try fsyncFd(dir);
}

pub const Lease = struct {
    directory_fd: c_int,
    lock_fd: c_int,
    id: ids.Id,
    expected: ?[32]u8,
    writable: bool,

    pub fn deinit(self: *Lease) void {
        if (self.lock_fd >= 0) fs.closeFd(self.lock_fd);
        fs.closeFd(self.directory_fd);
        self.* = undefined;
    }

    /// Writable opens take an exclusive writer lock. On SessionInUse, use
    /// open(..., false) to view history without a lock or permission to save.
    pub fn open(root: *fs.Root, id: ids.Id, writable: bool) !Lease {
        if (!ids.valid(id)) return error.InvalidSessionID;
        const dir = logs.openExistingDirectory(root) catch |err| return if (err == error.FileNotFound) error.ResumeNotFound else err;
        errdefer fs.closeFd(dir);
        if (!writable) return .{ .directory_fd = dir, .lock_fd = -1, .id = id, .expected = null, .writable = false };
        var buffer: [64]u8 = undefined;
        const path = try name(&buffer, id, ".resume-lock");
        const fd = fs.openAt(dir, path, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0o600);
        if (fd < 0) return fs.osError();
        errdefer fs.closeFd(fd);
        const stat = try fs.fileFromFd(fd).stat(root.io);
        if (stat.kind != .file) return error.UnsafeResumeFile;
        if (fs.flock(fd, fs.LOCK.EX | fs.LOCK.NB) != 0) return if (fs.errno() == .AGAIN) error.SessionInUse else fs.osError();
        return .{ .directory_fd = dir, .lock_fd = fd, .id = id, .expected = null, .writable = true };
    }

    /// Fresh IDs only. The lock is never unlinked or replaced; its inode remains
    /// the cooperative ownership anchor across atomic checkpoint replacements.
    pub fn create(root: *fs.Root, id: ids.Id) !Lease {
        if (!ids.valid(id)) return error.InvalidSessionID;
        const dir = try logs.openCheckpointDirectory(root);
        errdefer fs.closeFd(dir);
        var buffer: [64]u8 = undefined;
        const path = try name(&buffer, id, ".resume-lock");
        const fd = fs.openAt(dir, path, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0o600);
        if (fd < 0) return fs.osError();
        errdefer fs.closeFd(fd);
        if (std.c.fchmod(fd, 0o600) != 0) return fs.osError();
        if (fs.flock(fd, fs.LOCK.EX | fs.LOCK.NB) != 0) return error.SessionInUse;
        return .{ .directory_fd = dir, .lock_fd = fd, .id = id, .expected = null, .writable = true };
    }

    pub fn load(self: *Lease, root: *fs.Root) ![]u8 {
        const bytes = (try readFile(root, self.directory_fd, self.id)) orelse return error.ResumeNotFound;
        var digest: [32]u8 = undefined;
        Hash.hash(bytes, &digest, .{});
        self.expected = digest;
        return bytes;
    }

    pub fn getTitle(self: *const Lease, root: *fs.Root) session_metadata.Title {
        return readTitle(root, self.directory_fd, self.id);
    }

    /// Only a successfully saved or loaded checkpoint may acquire a sidecar.
    pub fn saveTitle(self: *Lease, root: *fs.Root, title: session_metadata.Title) !void {
        if (!self.writable) return error.ResumeReadOnly;
        if (self.expected == null) return error.ResumeNotFound;
        var buffer: [64]u8 = undefined;
        const path = try name(&buffer, self.id, ".title");
        try atomicWrite(root, self.directory_fd, path, title.text(), true);
    }

    pub fn save(self: *Lease, root: *fs.Root, bytes: []const u8) !void {
        if (!self.writable) return error.ResumeReadOnly;
        if (bytes.len == 0) return error.InvalidResumeLength;
        const old = try readFile(root, self.directory_fd, self.id);
        defer if (old) |value| root.allocator.free(value);
        if (self.expected) |expected| {
            var digest: [32]u8 = undefined;
            Hash.hash(old orelse return error.ResumeConflict, &digest, .{});
            if (!std.mem.eql(u8, &digest, &expected)) return error.ResumeConflict;
        } else if (old != null) return error.ResumeConflict;
        var buffer: [64]u8 = undefined;
        const path = try name(&buffer, self.id, ".session");
        try atomicWrite(root, self.directory_fd, path, bytes, self.expected != null);
        var digest: [32]u8 = undefined;
        Hash.hash(bytes, &digest, .{});
        self.expected = digest;
    }
};

/// Join outcome, not the poll clock. `done == false` is the only timeout:
/// a failure observed after the worker returns is that failure.
pub fn classifySave(done: bool, failure: ?anyerror) !void {
    if (!done) return error.ResumeSaveTimeout;
    if (failure) |err| return err;
}

/// Exit save on a worker so the caller can keep polling signals. The poll
/// window is not the outcome: cancel/join runs first, and only a worker that
/// is still unfinished after that join is `ResumeSaveTimeout`. A slow disk
/// that finishes during the join is success. Bytes and Root stay alive until
/// the join. A failed save never causes model or tool retries.
pub fn saveFinal(root: *fs.Root, id: ids.Id, existing: ?*Lease, bytes: []const u8) !void {
    const Work = struct {
        root: *fs.Root,
        id: ids.Id,
        existing: ?*Lease,
        bytes: []const u8,
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            self.save() catch |err| {
                self.failure = err;
            };
        }
        fn save(self: *@This()) !void {
            if (self.existing) |lease| return lease.save(self.root, self.bytes);
            var lease = try Lease.create(self.root, self.id);
            defer lease.deinit();
            try lease.save(self.root, self.bytes);
        }
    };
    var work = Work{ .root = root, .id = id, .existing = existing, .bytes = bytes };
    var future = try std.Io.concurrent(root.io, Work.run, .{&work});
    const start = std.Io.Clock.awake.now(root.io);
    while (!work.done.load(.acquire)) {
        if (start.durationTo(std.Io.Clock.awake.now(root.io)).toMilliseconds() >= 1000) break;
        try std.Io.sleep(root.io, .fromMilliseconds(2), .awake);
    }
    // Join before classifying. await does not request cancellation, so a slow
    // write that outlasts the poll can still publish successfully.
    // ResumeSaveTimeout is only when the worker is still unfinished after that join.
    future.await(root.io);
    return classifySave(work.done.load(.acquire), work.failure);
}
