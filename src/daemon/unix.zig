//! POSIX AF_UNIX transport for the daemon and instance-owned foreground worker.
//! 中文：Linux/macOS AF_UNIX 传输基础，只负责私有 runtime 目录、单实例锁、
//! 有界长度前缀帧与对端 UID 校验；不含业务 DTO、worker、TUI 或服务启动。
//!
//! Hard rules encoded here:
//! - sockets are SOCK_CLOEXEC | SOCK_NONBLOCK; every read/write is bounded by a
//!   caller deadline and a cancellation token, so an RPC thread never waits
//!   forever on a silent client.
//! - both ends verify kernel PID/UID (SO_PEERCRED or getpeereid+LOCAL_PEERPID).
//! - the runtime directory is 0700 and the socket 0600; symlinks, foreign
//!   owners and permissive modes are rejected, never repaired.
//! - the single-instance lock is a fixed inode flock and is never unlinked; it
//!   records which directory it locked and which inode it locked, so it can
//!   never authorize deleting an entry in another directory.
//! - stale socket cleanup requires that held lock, verifies the directory and
//!   the lock inode through the directory fd, and only removes a socket owned by
//!   this UID inside this directory (no recursion).
//! - sockets are created and stat/chmod/unlinked through the same directory fd:
//!   Linux uses /proc/self/fd; Darwin uses a C-only bind/SCM_RIGHTS helper.
//!   Only the real service listens; no Zig or allocator runs in the fork child.
//! - listener/directory cleanup only removes what this instance actually
//!   created, after re-checking dev/ino and owner.

const std = @import("std");
const c = std.c;
const linux = std.os.linux;
const builtin = @import("builtin");
const fs = @import("../platform/filesystem.zig");
const metadata = @import("../platform/metadata.zig");
const native = @import("../platform/ipc_native.zig");
const protocol = @import("../core/protocol.zig");

/// Maximum accepted payload of the four-byte wire length field. This is a
/// single-frame transport bound, not a queue capacity quota.
pub const max_frame_len: usize = 64 * 1024 * 1024;
/// Native sun_path capacity minus its terminating NUL (Linux 107, Darwin 103).
pub const max_socket_path_len = native.max_socket_path_len;
/// Owned NONBLOCK/CLOEXEC pair; Darwin also configures SO_NOSIGPIPE on both ends.
pub const socketPair = native.socketPair;
/// Longest accepted single path component (socket/lock file name).
pub const max_name_len: usize = 63;

const header_size: usize = 4;
const poll_slice_ms: i64 = 50;
const connect_retry_ms: i64 = 10;

/// Device+inode identity; inode numbers alone are not globally unique.
pub const Identity = struct {
    dev_major: u32,
    dev_minor: u32,
    ino: u64,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.dev_major == b.dev_major and a.dev_minor == b.dev_minor and a.ino == b.ino;
    }

    fn from(st: metadata.Metadata) Identity {
        return .{ .dev_major = st.dev_major, .dev_minor = st.dev_minor, .ino = st.ino };
    }
};

/// Kernel-reported PID/UID/GID, never client-supplied (including on Darwin).
pub const Credentials = native.Credentials;

/// Per-operation bounds. `timeout_ms` is the total budget for the call; 0 means
/// "do not wait" (returns error.Timeout). There is intentionally no infinite
/// wait mode. Cancellation is polled at least every `poll_slice_ms`.
///
/// `progress_fn` is an optional side-channel that the owner thread runs on
/// every wait tick (poll retry, partial read/write, not-ready wait), so a caller
/// such as the worker RPC loop can keep pumping host work while this call is
/// blocked without an async sender. It never resets the deadline: `timeout_ms`
/// is still measured from the single `Deadline.init`. Its errors (including
/// `error.Canceled`) propagate unchanged out of the wait call. Both fields are
/// null by default, which keeps every existing call's semantics.
pub const Wait = struct {
    io: std.Io,
    timeout_ms: u32,
    cancel: ?*const protocol.Cancellation = null,
    progress_context: ?*anyopaque = null,
    progress_fn: ?*const fn (?*anyopaque) anyerror!void = null,
};

const Deadline = struct {
    io: std.Io,
    start: std.Io.Timestamp,
    timeout_ms: u32,
    cancel: ?*const protocol.Cancellation,
    progress_context: ?*anyopaque,
    progress_fn: ?*const fn (?*anyopaque) anyerror!void,

    fn init(wait: Wait) Deadline {
        return .{
            .io = wait.io,
            .start = std.Io.Clock.awake.now(wait.io),
            .timeout_ms = wait.timeout_ms,
            .cancel = wait.cancel,
            .progress_context = wait.progress_context,
            .progress_fn = wait.progress_fn,
        };
    }

    fn remainingMs(self: *const Deadline) i64 {
        const elapsed = self.start.untilNow(self.io, .awake).toMilliseconds();
        return @as(i64, self.timeout_ms) - elapsed;
    }

    fn checkCancel(self: *const Deadline) !void {
        if (self.cancel) |token| {
            if (token.isRequested()) return error.Canceled;
        }
    }

    /// One wait-loop tick, on the calling thread: optional progress first (so a
    /// callback may request cancellation or fail), then cancellation. Errors are
    /// returned as-is; the deadline itself is never re-based.
    fn tick(self: *const Deadline) !void {
        if (self.progress_fn) |progress| try progress(self.progress_context);
        try self.checkCancel();
    }
};

// ---------------------------------------------------------------------------
// errno mapping
// ---------------------------------------------------------------------------

/// Read errno of a failed libc call; must run before the next libc call.
const libcErrno = native.errno;

fn libcFail() anyerror {
    return mapErrno(libcErrno());
}

const mapErrno = native.mapError;

// ---------------------------------------------------------------------------
// stat helpers (all libc; errno via libcErrno)
// ---------------------------------------------------------------------------

const statAt = metadata.statAt;
const statFd = metadata.statFd;

fn isDir(mode: u16) bool {
    return mode & c.S.IFMT == c.S.IFDIR;
}

fn isSock(mode: u16) bool {
    return mode & c.S.IFMT == c.S.IFSOCK;
}

fn isReg(mode: u16) bool {
    return mode & c.S.IFMT == c.S.IFREG;
}

fn isLink(mode: u16) bool {
    return mode & c.S.IFMT == c.S.IFLNK;
}

fn perms(mode: u16) u16 {
    return mode & 0o777;
}

/// 0600/0700 socket permissions are fsck'd without following a swapped symlink
/// when the kernel offers fchmodat2; the caller re-verifies identity afterwards.
fn chmodNoFollow(fd: c.fd_t, path_z: [*:0]const u8, mode: u32) !void {
    const permissions = std.math.cast(c.mode_t, mode) orelse return error.InvalidFileMode;
    if (builtin.os.tag == .macos) {
        if (c.fchmodat(fd, path_z, permissions, c.AT.SYMLINK_NOFOLLOW) != 0) return libcFail();
        return;
    }
    if (builtin.os.tag == .linux) {
        const rc = linux.fchmodat2(fd, path_z, mode, linux.AT.SYMLINK_NOFOLLOW);
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .NOSYS, .OPNOTSUPP, .INVAL => {},
            else => |e| return mapErrno(e),
        }
        // Pre-6.5 Linux: private directory plus post-verification keep fallback honest.
        if (c.fchmodat(fd, path_z, permissions, 0) != 0) return libcFail();
    }
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_name_len) return error.InvalidName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;
    if (std.mem.findScalar(u8, name, '/') != null) return error.InvalidName;
    if (std.mem.findScalar(u8, name, 0) != null) return error.InvalidName;
}

fn validateSocketPath(path: []const u8) !void {
    if (path.len == 0 or path.len > max_socket_path_len) return error.InvalidPath;
    if (path[0] != '/') return error.InvalidPath;
    if (std.mem.findScalar(u8, path, 0) != null) return error.InvalidPath;
}

fn validatePrivateDir(st: metadata.Metadata, uid: u32) !void {
    if (isLink(st.mode)) return error.SymlinkNotAllowed;
    if (!isDir(st.mode)) return error.NotDirectory;
    if (st.uid != uid) return error.NotOwned;
    if (perms(st.mode) != 0o700) return error.InsecurePermissions;
}

// ---------------------------------------------------------------------------
// private runtime directory
// ---------------------------------------------------------------------------

/// A validated, UID-private directory holding sockets and the instance lock.
/// 中文：该目录必须属于本 UID 且权限 0700；deinit 只关 fd，不删目录。
pub const Directory = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    path: []u8,
    uid: u32,
    identity: Identity,
    /// true only when this call created the leaf directory.
    created: bool,

    /// Resolve the daemon directory from an explicit environment map.
    /// `$XDG_RUNTIME_DIR` (when non-empty) must be an absolute, real, UID-owned
    /// 0700 directory; `<xdg>/thin` is then created/verified. Otherwise a
    /// UID-private `/tmp/thin-<uid>` is used after checking `/tmp` itself is a
    /// root-owned sticky, world-writable directory. No global environment is
    /// read here.
    pub fn resolve(allocator: std.mem.Allocator, environ: ?*const std.process.Environ.Map, uid: u32) !Directory {
        if (environ) |env| {
            if (env.get("XDG_RUNTIME_DIR")) |raw| {
                if (raw.len != 0) return resolveBase(allocator, raw, uid);
            }
        }
        return resolveFallback(allocator, uid);
    }

    /// Explicit base path (already existing `$XDG_RUNTIME_DIR`-style directory).
    /// Creates/verifies `<base>/thin`.
    pub fn resolveBase(allocator: std.mem.Allocator, base_path: []const u8, uid: u32) !Directory {
        if (base_path.len == 0 or base_path.len > 4096 or !std.fs.path.isAbsolute(base_path)) return error.InvalidPath;
        if (std.mem.findScalar(u8, base_path, 0) != null) return error.InvalidPath;
        if (base_path.len + "/thin".len > max_socket_path_len) return error.NameTooLong;

        const canonical = try metadata.systemPath(allocator, base_path);
        defer allocator.free(canonical);
        if (canonical.len + "/thin".len > max_socket_path_len) return error.NameTooLong;
        const base_fd = try metadata.openDirectoryPath(allocator, canonical);
        defer fs.closeFd(base_fd);
        try validatePrivateDir(try statFd(base_fd), uid);
        return createChild(allocator, base_fd, canonical, "thin", uid);
    }

    /// Low-level: create/verify `<parent_path>/<name>` as a 0700 UID-owned real
    /// directory. The parent must be a real directory (its own mode/owner policy
    /// is the caller's decision, e.g. root-owned sticky /tmp).
    pub fn resolveUnder(allocator: std.mem.Allocator, parent_path: []const u8, name: []const u8, uid: u32) !Directory {
        try validateName(name);
        if (parent_path.len == 0 or !std.fs.path.isAbsolute(parent_path)) return error.InvalidPath;
        if (std.mem.findScalar(u8, parent_path, 0) != null) return error.InvalidPath;
        if (parent_path.len + 1 + name.len > max_socket_path_len) return error.NameTooLong;

        const canonical = try metadata.systemPath(allocator, parent_path);
        defer allocator.free(canonical);
        if (canonical.len + 1 + name.len > max_socket_path_len) return error.NameTooLong;
        const parent_fd = try metadata.openDirectoryPath(allocator, canonical);
        defer fs.closeFd(parent_fd);
        return createChild(allocator, parent_fd, canonical, name, uid);
    }

    /// Fallback when `$XDG_RUNTIME_DIR` is unset: `/tmp/thin-<uid>`.
    pub fn resolveFallback(allocator: std.mem.Allocator, uid: u32) !Directory {
        const tmp_path = try metadata.systemPath(allocator, "/tmp");
        defer allocator.free(tmp_path);
        const tmp_fd = try metadata.openDirectoryPath(allocator, tmp_path);
        defer fs.closeFd(tmp_fd);
        const tmp_st = try statFd(tmp_fd);
        if (!isDir(tmp_st.mode) or tmp_st.uid != 0) return error.InsecureRuntimeBase;
        if (tmp_st.mode & c.S.ISVTX == 0) return error.InsecureRuntimeBase;
        if (perms(tmp_st.mode) & 0o002 == 0) return error.InsecureRuntimeBase;

        var buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "thin-{d}", .{uid});
        return createChild(allocator, tmp_fd, tmp_path, name, uid);
    }

    /// Build `<dir>/<name>` for a socket/lock path, enforcing the AF_UNIX limit.
    pub fn join(self: *const Directory, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        try validateName(name);
        if (self.path.len + 1 + name.len > max_socket_path_len) return error.NameTooLong;
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.path, name });
    }

    /// Close the descriptor and free the path. Never removes the directory.
    pub fn deinit(self: *Directory) void {
        if (self.fd >= 0) {
            fs.closeFd(self.fd);
            self.fd = -1;
        }
        self.allocator.free(self.path);
    }

    /// Remove the leaf directory only when this instance created it, it is still
    /// the same inode, and it is empty. Never recursive; never touches parents.
    pub fn removeIfEmpty(self: *Directory) !void {
        if (!self.created) return;
        const parent = std.fs.path.dirname(self.path) orelse return error.InvalidPath;
        const parent_fd = metadata.openDirectoryPath(self.allocator, parent) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer fs.closeFd(parent_fd);
        const name_z = try self.allocator.dupeSentinel(u8, std.fs.path.basename(self.path), 0);
        defer self.allocator.free(name_z);
        const st = statAt(parent_fd, name_z, true) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (!isDir(st.mode)) return error.NotDirectory;
        if (st.uid != self.uid) return error.NotOwned;
        if (!Identity.from(st).eql(self.identity)) return error.IdentityChanged;
        if (c.unlinkat(parent_fd, name_z, c.AT.REMOVEDIR) != 0) return libcFail();
    }
};

fn createChild(allocator: std.mem.Allocator, parent_fd: c.fd_t, parent_path: []const u8, name: []const u8, uid: u32) !Directory {
    const name_z = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(name_z);

    var created = false;
    if (c.mkdirat(parent_fd, name_z, 0o700) == 0) {
        created = true;
    } else {
        const e = libcErrno();
        if (e != .EXIST) return mapErrno(e);
    }

    // Anything already present must be a real 0700 directory owned by this UID;
    // symlinks are reported as such instead of being followed or replaced.
    const st = try statAt(parent_fd, name_z, true);
    try validatePrivateDir(st, uid);
    const fd = try fs.openDirectory(parent_fd, name_z);
    errdefer fs.closeFd(fd);
    const opened = try statFd(fd);
    try validatePrivateDir(opened, uid);
    if (!Identity.from(opened).eql(Identity.from(st))) return error.IdentityChanged;
    const entry = try statAt(parent_fd, name_z, true);
    if (!Identity.from(entry).eql(Identity.from(opened))) return error.IdentityChanged;

    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent_path, name });
    errdefer allocator.free(path);
    const result: Directory = .{
        .allocator = allocator,
        .fd = fd,
        .path = path,
        .uid = uid,
        .identity = Identity.from(opened),
        .created = created,
    };
    try verifyDirectoryPath(&result);
    return result;
}

// ---------------------------------------------------------------------------
// single-daemon lock (fixed inode, never unlinked)
// ---------------------------------------------------------------------------

/// Exclusive, non-blocking flock on a fixed lock inode inside the private
/// directory. The lock file is created 0600 if missing and is never truncated
/// or unlinked; releasing the lock keeps the inode for the next owner.
pub const Lock = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    path: []u8,
    uid: u32,
    held: bool,
    /// Identity of the directory this lock was taken in (`statFd(dir.fd)`).
    dir_identity: Identity,
    /// Identity of the lock file inode the flock is held on.
    file_identity: Identity,
    /// Single-segment lock file name. Fixed storage, so copying a `Lock` never
    /// duplicates ownership of an allocation.
    name_buf: [max_name_len + 1]u8 = @splat(0),
    name_len: usize = 0,

    /// NUL-terminated lock file name as it must appear inside the directory.
    pub fn lockName(self: *const Lock) [:0]const u8 {
        return self.name_buf[0..self.name_len :0];
    }

    pub fn acquire(allocator: std.mem.Allocator, dir: *const Directory, name: []const u8) !Lock {
        try validateName(name);

        // The fd must still be the directory this Directory describes; otherwise
        // the identities recorded below would describe something else.
        const dir_now = try statFd(dir.fd);
        if (!isDir(dir_now.mode)) return error.NotDirectory;
        if (!Identity.from(dir_now).eql(dir.identity)) return error.IdentityChanged;

        const name_z = try allocator.dupeSentinel(u8, name, 0);
        defer allocator.free(name_z);

        // O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK; no O_TRUNC.
        const fd = fs.openAt(
            dir.fd,
            name_z,
            .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true },
            0o600,
        );
        if (fd < 0) return fs.osError();
        errdefer fs.closeFd(fd);

        const st = try statFd(fd);
        if (!isReg(st.mode)) return error.NotARegularFile;
        if (st.uid != dir.uid) return error.NotOwned;
        if (perms(st.mode) != 0o600) return error.InsecurePermissions;
        if (st.nlink != 1) return error.UnexpectedLinkCount;
        const file_identity = Identity.from(st);

        // The directory entry must still name this very inode, so a later
        // cleanup can prove the lock file was not swapped underneath us.
        const entry = try statAt(dir.fd, name_z, true);
        if (!Identity.from(entry).eql(file_identity)) return error.IdentityChanged;

        if (fs.flock(fd, fs.LOCK.EX | fs.LOCK.NB) != 0) {
            const e = libcErrno();
            if (e == .AGAIN) return error.AlreadyRunning;
            return mapErrno(e);
        }

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir.path, name });
        var lock = Lock{
            .allocator = allocator,
            .fd = fd,
            .path = path,
            .uid = dir.uid,
            .held = true,
            .dir_identity = Identity.from(dir_now),
            .file_identity = file_identity,
        };
        @memcpy(lock.name_buf[0..name.len], name);
        lock.name_len = name.len;
        return lock;
    }

    pub fn release(self: *Lock) void {
        if (!self.held) return;
        self.held = false;
        self.name_len = 0;
        _ = fs.flock(self.fd, fs.LOCK.UN); // The inode stays on disk.
        fs.closeFd(self.fd);
        self.fd = -1;
        if (self.path.len != 0) self.allocator.free(self.path);
        self.path = &.{};
    }

    pub fn isHeld(self: *const Lock) bool {
        return self.held;
    }
};

/// Remove a stale socket entry. Caller must hold the lock *of this directory*:
/// the lock records the directory identity and the lock file inode, and both are
/// re-verified through `dir.fd` so a lock held elsewhere (or a replaced lock
/// path) is refused with no unlink. Only a socket owned by that UID inside this
/// directory is removed, and never recursively.
pub fn removeStaleSocket(lock: *const Lock, dir: *const Directory, name: []const u8) !bool {
    if (!lock.isHeld() or lock.fd < 0) return error.LockNotHeld;
    if (lock.uid != dir.uid) return error.UidMismatch;
    try validateName(name);

    // The held lock must be *this* directory's lock: a lock taken in directory A
    // authorizes nothing in directory B, however equal the two look.
    const dir_now = try statFd(dir.fd);
    if (!isDir(dir_now.mode)) return error.NotDirectory;
    if (!Identity.from(dir_now).eql(lock.dir_identity)) return error.DirectoryMismatch;

    // The lock inode we hold must still be the fixed lock name inside the
    // directory; a replaced lock path means the lock no longer describes it.
    const lock_name = lock.lockName();
    if (lock_name.len == 0) return error.LockNotHeld;
    const held_st = try statFd(lock.fd);
    if (!Identity.from(held_st).eql(lock.file_identity)) return error.LockIdentityChanged;
    const lock_entry = statAt(dir.fd, lock_name.ptr, true) catch |err| switch (err) {
        error.FileNotFound => return error.LockIdentityChanged,
        else => return err,
    };
    if (isLink(lock_entry.mode) or !isReg(lock_entry.mode)) return error.LockIdentityChanged;
    if (!Identity.from(lock_entry).eql(lock.file_identity)) return error.LockIdentityChanged;

    const name_z = try dir.allocator.dupeSentinel(u8, name, 0);
    defer dir.allocator.free(name_z);

    const st = statAt(dir.fd, name_z, true) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (isLink(st.mode)) return error.SymlinkNotAllowed;
    if (!isSock(st.mode)) return error.NotASocket;
    if (st.uid != dir.uid) return error.NotOwned;

    if (c.unlinkat(dir.fd, name_z, 0) != 0) return libcFail();
    return true;
}

// ---------------------------------------------------------------------------
// sockets
// ---------------------------------------------------------------------------

const socketFd = native.socket;
/// SO_PEERCRED on Linux; getpeereid + LOCAL_PEERPID on Darwin. Fail closed.
pub const socketCredentials = native.credentials;

fn ensureSocketFile(dir_fd: c.fd_t, name_z: [*:0]const u8, uid: u32, expected: Identity) !void {
    const st = try statAt(dir_fd, name_z, true);
    if (isLink(st.mode)) return error.SymlinkNotAllowed;
    if (!isSock(st.mode)) return error.NotASocket;
    if (st.uid != uid) return error.NotOwned;
    if (!Identity.from(st).eql(expected)) return error.IdentityChanged;

    if (perms(st.mode) != 0o600) {
        try chmodNoFollow(dir_fd, name_z, 0o600);
        const again = try statAt(dir_fd, name_z, true);
        if (!Identity.from(again).eql(expected)) return error.IdentityChanged;
        if (!isSock(again.mode) or again.uid != uid or perms(again.mode) != 0o600) return error.InsecurePermissions;
    }
}

/// The exported socket path stays the real directory path, so it must still name
/// the very directory `dir.fd` refers to; a renamed or replaced directory would
/// publish a path that leads elsewhere.
fn verifyDirectoryPath(dir: *const Directory) !void {
    const now = try statFd(dir.fd);
    try validatePrivateDir(now, dir.uid);
    if (!Identity.from(now).eql(dir.identity)) return error.DirectoryMoved;

    const path_fd = metadata.openDirectoryPath(dir.allocator, dir.path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.SymlinkNotAllowed, error.IdentityChanged => return error.DirectoryMoved,
        else => return err,
    };
    defer fs.closeFd(path_fd);
    const on_path = try statFd(path_fd);
    if (!isDir(on_path.mode)) return error.DirectoryMoved;
    if (!Identity.from(on_path).eql(dir.identity)) return error.DirectoryMoved;
}

/// Test-only injection point for the fallible steps after a successful bind.
/// Production binds always pass `.none`.
const BindFault = enum { none, after_bind };

fn unlinkIfMatches(dir_fd: c.fd_t, name_z: [*:0]const u8, expected: Identity, uid: u32) void {
    const st = statAt(dir_fd, name_z, true) catch return;
    if (!isSock(st.mode) or st.uid != uid) return;
    if (!Identity.from(st).eql(expected)) return;
    _ = c.unlinkat(dir_fd, name_z, 0);
}

fn waitReady(fd: c.fd_t, events: i16, deadline: *const Deadline) !void {
    while (true) {
        try deadline.tick();
        const remaining = deadline.remainingMs();
        if (remaining <= 0) return error.Timeout;
        const slice: c_int = @intCast(@min(remaining, poll_slice_ms));
        var fds = [_]c.pollfd{.{ .fd = fd, .events = events }};
        const rc = c.poll(&fds, fds.len, slice);
        if (rc < 0) {
            const e = libcErrno();
            if (e == .INTR) continue;
            return mapErrno(e);
        }
        if (rc == 0) continue; // re-check cancellation and the deadline
        const revents = fds[0].revents;
        if (revents & events != 0) return;
        if (revents & (c.POLL.ERR | c.POLL.HUP | c.POLL.NVAL) != 0) return;
    }
}

fn sleepSlice(deadline: *const Deadline) !void {
    try deadline.tick();
    const remaining = deadline.remainingMs();
    if (remaining <= 0) return error.Timeout;
    const slice: c_int = @intCast(@min(remaining, connect_retry_ms));
    var fds: [0]c.pollfd = undefined;
    const rc = c.poll(&fds, 0, slice);
    if (rc < 0) {
        const e = libcErrno();
        if (e == .INTR) return;
        return mapErrno(e);
    }
}

pub const BindOptions = struct {
    /// When given, the caller proves single-instance ownership and a stale
    /// same-UID socket at `name` is removed before binding. Without it an
    /// existing entry is never removed: the bind fails with AddressInUse.
    lock: ?*const Lock = null,
    backlog: u32 = 64,
};

/// Listening AF_UNIX socket owned by this instance. `deinit` closes the fd and
/// unlinks the socket only when the entry is still the exact inode it bound.
pub const Listener = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    dir_fd: c.fd_t,
    name_z: [:0]u8,
    path: []u8,
    uid: u32,
    identity: Identity,
    bound: bool,

    pub fn bind(allocator: std.mem.Allocator, dir: *const Directory, name: []const u8, options: BindOptions) !Listener {
        return bindInternal(allocator, dir, name, options, .none);
    }

    fn bindInternal(
        allocator: std.mem.Allocator,
        dir: *const Directory,
        name: []const u8,
        options: BindOptions,
        fault: BindFault,
    ) !Listener {
        try validateName(name);
        const path = try dir.join(allocator, name);
        errdefer allocator.free(path);
        const name_z = try allocator.dupeSentinel(u8, name, 0);
        errdefer allocator.free(name_z);

        // Fail closed about the published path before mutating anything, then let
        // the held lock (and only that lock, in this directory) drop a stale
        // socket, and only then create the new one.
        try verifyDirectoryPath(dir);

        if (options.lock) |lock| {
            if (!lock.isHeld()) return error.LockNotHeld;
            if (lock.uid != dir.uid) return error.UidMismatch;
            _ = try removeStaleSocket(lock, dir, name);
        }

        const bound = try native.bindAt(allocator, dir.fd, name_z);
        const fd = bound.fd;
        errdefer fs.closeFd(fd);

        // Own cleanup immediately using the identity captured at bind, including
        // the helper's original identity on Darwin. Do not adopt a later snapshot
        // of a replaced name (the socket fd's own identity need not be the node).
        const identity: Identity = .{ .dev_major = bound.dev_major, .dev_minor = bound.dev_minor, .ino = bound.ino };
        errdefer unlinkIfMatches(dir.fd, name_z, identity, dir.uid);
        if (fault == .after_bind) return error.InjectedBindFailure;

        try ensureSocketFile(dir.fd, name_z, dir.uid, identity);

        // Recheck after helper exit/bind, before publishing a path or listening.
        try verifyDirectoryPath(dir);
        if (c.listen(fd, std.math.clamp(options.backlog, 1, 4096)) != 0) return libcFail();
        try verifyDirectoryPath(dir);

        // Anchored "down" lookup: the listener keeps its own descriptor to the
        // same directory even after the caller deinits `Directory`.
        const dir_fd = try fs.openDirectory(dir.fd, ".");
        return .{
            .allocator = allocator,
            .fd = fd,
            .dir_fd = dir_fd,
            .name_z = name_z,
            .path = path,
            .uid = dir.uid,
            .identity = identity,
            .bound = true,
        };
    }

    /// Accept one connection and verify the kernel-reported peer UID. A peer
    /// with another UID is closed and reported as error.PeerUidMismatch; the
    /// listener itself stays usable.
    pub fn accept(self: *Listener, wait: Wait) !Connection {
        var deadline = Deadline.init(wait);
        while (true) {
            try waitReady(self.fd, c.POLL.IN, &deadline);
            const fd = native.accept(self.fd) catch |err| switch (err) {
                error.WouldBlock, error.Interrupted, error.ConnectionAborted => continue,
                else => return err,
            };
            errdefer fs.closeFd(fd);
            const peer = try socketCredentials(fd);
            if (peer.uid != self.uid) return error.PeerUidMismatch;
            return Connection.init(self.allocator, fd, peer);
        }
    }

    /// Single nonblocking accept attempt. A quiet listener never waits on the
    /// owner thread; caller readiness polling owns scheduling and deadlines.
    pub fn acceptStep(self: *Listener) !?Connection {
        const fd = native.accept(self.fd) catch |err| switch (err) {
            error.WouldBlock, error.Interrupted, error.ConnectionAborted => return null,
            else => return err,
        };
        errdefer fs.closeFd(fd);
        const peer = try socketCredentials(fd);
        if (peer.uid != self.uid) return error.PeerUidMismatch;
        return Connection.init(self.allocator, fd, peer);
    }

    /// Close the listening descriptor only; the socket file is left for deinit.
    pub fn close(self: *Listener) void {
        if (self.fd >= 0) {
            fs.closeFd(self.fd);
            self.fd = -1;
        }
    }

    /// Close and remove the socket only if it is still this instance's inode.
    pub fn deinit(self: *Listener) void {
        self.close();
        if (self.bound) {
            unlinkIfMatches(self.dir_fd, self.name_z, self.identity, self.uid);
            self.bound = false;
        }
        if (self.dir_fd >= 0) {
            fs.closeFd(self.dir_fd);
            self.dir_fd = -1;
        }
        self.allocator.free(self.name_z);
        self.allocator.free(self.path);
    }

    pub fn socketPath(self: *const Listener) []const u8 {
        return self.path;
    }

    pub fn socketIdentity(self: *const Listener) Identity {
        return self.identity;
    }

    pub fn expectedUid(self: *const Listener) u32 {
        return self.uid;
    }
};

fn connectPath(fd: c.fd_t, path: []const u8, deadline: *const Deadline) !void {
    var addr = try native.address(path);
    while (true) {
        try deadline.tick();
        if (c.connect(fd, @ptrCast(&addr), native.addressLength(path)) == 0) return;
        switch (libcErrno()) {
            .ISCONN => return,
            .INTR => continue,
            // Linux AF_UNIX returns EAGAIN when backlog is full: retry connect.
            .AGAIN => try sleepSlice(deadline),
            .INPROGRESS, .ALREADY => {
                try waitReady(fd, c.POLL.OUT, deadline);
                var pending: c_int = 0;
                var len: c.socklen_t = @sizeOf(c_int);
                if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &pending, &len) != 0) return libcFail();
                if (len != @sizeOf(c_int)) return error.UnexpectedSystemError;
                if (pending != 0) return mapErrno(@fromBackingInt(@intCast(pending)));
                return;
            },
            else => |e| return mapErrno(e),
        }
    }
}

/// Connect to an existing endpoint and verify native kernel PID/UID. The path entry
/// must be a real socket owned by `expected_uid`; symlinks are refused.
pub fn connect(allocator: std.mem.Allocator, path: []const u8, expected_uid: u32, wait: Wait) !Connection {
    try validateSocketPath(path);

    const canonical = try metadata.systemPath(allocator, path);
    defer allocator.free(canonical);
    try validateSocketPath(canonical);
    const parent_path = std.fs.path.dirname(canonical) orelse return error.InvalidPath;
    const parent_fd = try metadata.openDirectoryPath(allocator, parent_path);
    defer fs.closeFd(parent_fd);
    const parent_identity = Identity.from(try statFd(parent_fd));
    const name_z = try allocator.dupeSentinel(u8, std.fs.path.basename(canonical), 0);
    defer allocator.free(name_z);
    const st = try statAt(parent_fd, name_z, true);
    if (isLink(st.mode)) return error.SymlinkNotAllowed;
    if (!isSock(st.mode)) return error.NotASocket;
    if (st.uid != expected_uid) return error.NotOwned;

    const fd = try socketFd();
    errdefer fs.closeFd(fd);

    var deadline = Deadline.init(wait);
    try connectPath(fd, canonical, &deadline);

    const peer = try socketCredentials(fd);
    if (peer.uid != expected_uid) return error.PeerUidMismatch;
    const again = try statAt(parent_fd, name_z, true);
    if (!Identity.from(again).eql(Identity.from(st)) or !isSock(again.mode) or
        again.uid != expected_uid) return error.IdentityChanged;
    const path_fd = try metadata.openDirectoryPath(allocator, parent_path);
    defer fs.closeFd(path_fd);
    if (!Identity.from(try statFd(path_fd)).eql(parent_identity)) return error.DirectoryMoved;
    return Connection.init(allocator, fd, peer);
}

// ---------------------------------------------------------------------------
// bounded length-prefixed frames
// ---------------------------------------------------------------------------

const ReadState = enum { header, body };

/// One AF_UNIX connection. Framing is a 4-byte big-endian length followed by
/// that many payload bytes. Read timeouts/cancellation preserve the partial
/// frame so the next call continues it; EOF, truncated frames and oversized
/// lengths poison the stream.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    /// Kernel-verified peer at accept/connect time.
    peer: Credentials,

    state: ReadState = .header,
    header: [header_size]u8 = @splat(0),
    header_read: usize = 0,
    declared: usize = 0,
    body: std.ArrayList(u8) = .empty,
    body_read: usize = 0,
    write_progress: usize = 0,
    poisoned: bool = false,
    /// Owned header+payload for the step writer. Exactly one frame may be
    /// pending; synchronous writes cannot interleave with it.
    outgoing: []u8 = &.{},
    outgoing_offset: usize = 0,

    pub const ReadStep = union(enum) { pending, eof, frame: []u8 };
    pub const step_bytes: usize = 64 * 1024;

    /// Takes ownership of `fd`; peer must already be verified. Native callers
    /// must supply a NONBLOCK/CLOEXEC fd with Darwin SO_NOSIGPIPE already set;
    /// use socketPair for fixtures. Never set it lazily after a peer has closed.
    pub fn init(allocator: std.mem.Allocator, fd: c.fd_t, peer: Credentials) Connection {
        return .{ .allocator = allocator, .fd = fd, .peer = peer };
    }

    /// Read one frame. Returns null on a clean EOF at a frame boundary. The
    /// returned payload is owned by the caller and must be freed with the same
    /// allocator. Timeout/cancel keep the partial frame; other I/O failures
    /// poison the connection because the byte stream can no longer be trusted.
    pub fn readFrame(self: *Connection, wait: Wait) !?[]u8 {
        if (self.poisoned) return error.StreamPoisoned;
        var deadline = Deadline.init(wait);

        if (self.state == .header) {
            while (self.header_read < header_size) {
                const maybe = try self.readAvailable(self.header[self.header_read..], &deadline);
                const n = maybe orelse {
                    if (self.header_read == 0) return null;
                    self.poisoned = true;
                    return error.TruncatedFrame;
                };
                self.header_read += n;
            }
            const declared = std.mem.readInt(u32, &self.header, .big);
            if (@as(usize, declared) > max_frame_len) {
                self.poisoned = true;
                return error.FrameTooLarge;
            }
            self.declared = declared;
            self.state = .body;
        }

        var chunk: [step_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &chunk);
        while (self.body_read < self.declared) {
            const want = @min(chunk.len, self.declared - self.body_read);
            const maybe = try self.readAvailable(chunk[0..want], &deadline);
            const n = maybe orelse {
                self.freeBody();
                self.clearFrame();
                self.poisoned = true;
                return error.TruncatedFrame;
            };
            self.appendBody(chunk[0..n]) catch |err| {
                self.poisoned = true;
                return err;
            };
            self.body_read += n;
        }

        const frame = try self.takeBody();
        self.clearFrame();
        return frame;
    }

    /// At most two immediate recv calls (header, then a bounded body slice).
    /// Partial frames remain owned across turns; EOF inside a frame is fatal.
    /// MSG_DONTWAIT also makes this safe for an externally supplied blocking fd.
    pub fn readStep(self: *Connection) !ReadStep {
        if (self.poisoned) return error.StreamPoisoned;
        if (self.state == .header) {
            const n = self.receiveStep(self.header[self.header_read..]) catch |err| switch (err) {
                error.WouldBlock => return .pending,
                else => return err,
            };
            if (n == 0) {
                if (self.header_read == 0) return .eof;
                self.poisoned = true;
                return error.TruncatedFrame;
            }
            self.header_read += n;
            if (self.header_read < header_size) return .pending;
            const declared = std.mem.readInt(u32, &self.header, .big);
            if (@as(usize, declared) > max_frame_len) {
                self.poisoned = true;
                return error.FrameTooLarge;
            }
            self.declared = declared;
            self.state = .body;
        }
        if (self.body_read < self.declared) {
            var chunk: [step_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &chunk);
            const want = @min(chunk.len, self.declared - self.body_read);
            const n = self.receiveStep(chunk[0..want]) catch |err| switch (err) {
                error.WouldBlock => return .pending,
                else => return err,
            };
            if (n == 0) {
                self.poisoned = true;
                return error.TruncatedFrame;
            }
            self.appendBody(chunk[0..n]) catch |err| {
                self.poisoned = true;
                return err;
            };
            self.body_read += n;
            if (self.body_read < self.declared) return .pending;
        }
        const frame = try self.takeBody();
        self.clearFrame();
        return .{ .frame = frame };
    }

    fn receiveStep(self: *Connection, bytes: []u8) !usize {
        const n = c.recv(self.fd, bytes.ptr, bytes.len, native.recv_flags);
        if (n >= 0) return @intCast(n);
        const err = libcErrno();
        if (err == .AGAIN or err == .INTR) return error.WouldBlock;
        self.poisoned = true;
        return mapErrno(err);
    }

    /// Copy once before publication; the caller may immediately wipe its reply.
    /// No write, wait or callback occurs while queueing.
    pub fn queueFrame(self: *Connection, payload: []const u8) !void {
        if (self.poisoned) return error.StreamPoisoned;
        if (self.writePending()) return error.WriteInProgress;
        if (payload.len > max_frame_len) return error.FrameTooLarge;
        const frame_len = std.math.add(usize, header_size, payload.len) catch return error.FrameTooLarge;
        const frame = try self.allocator.alloc(u8, frame_len);
        std.mem.writeInt(u32, frame[0..header_size], @intCast(payload.len), .big);
        @memcpy(frame[header_size..], payload);
        self.outgoing = frame;
        self.outgoing_offset = 0;
    }

    pub fn writePending(self: *const Connection) bool {
        return self.outgoing.len != 0;
    }

    /// One bounded nonblocking send. A false result means pending, not failure.
    /// EAGAIN never discards or poisons a partial frame. The caller owns the
    /// absolute deadline and must close, not restart, a timed-out partial frame.
    pub fn writeStep(self: *Connection) !bool {
        if (self.poisoned) return error.StreamPoisoned;
        if (!self.writePending()) return true;
        const end = @min(self.outgoing.len, self.outgoing_offset + step_bytes);
        const bytes = self.outgoing[self.outgoing_offset..end];
        const n = c.send(self.fd, bytes.ptr, bytes.len, native.step_send_flags);
        if (n < 0) {
            const err = libcErrno();
            if (err == .AGAIN or err == .INTR) return false;
            self.poisoned = true;
            return mapErrno(err);
        }
        if (n == 0) {
            self.poisoned = true;
            return error.ConnectionClosed;
        }
        self.outgoing_offset += @intCast(n);
        if (self.outgoing_offset != self.outgoing.len) return false;
        self.clearOutgoing();
        return true;
    }

    fn clearOutgoing(self: *Connection) void {
        std.crypto.secureZero(u8, self.outgoing);
        self.allocator.free(self.outgoing);
        self.outgoing = &.{};
        self.outgoing_offset = 0;
    }

    /// Write one frame. A payload above `max_frame_len` is rejected before any
    /// byte is written. Any failure after a partial write poisons the stream;
    /// a timeout/cancel before the first byte leaves the frame retryable.
    pub fn writeFrame(self: *Connection, payload: []const u8, wait: Wait) !void {
        if (self.poisoned) return error.StreamPoisoned;
        if (self.writePending()) return error.WriteInProgress;
        if (payload.len > max_frame_len) return error.FrameTooLarge;

        var deadline = Deadline.init(wait);
        var header: [header_size]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(payload.len), .big);

        self.write_progress = 0;
        self.writeAll(&header, &deadline) catch |err| return self.failWrite(err);
        self.writeAll(payload, &deadline) catch |err| return self.failWrite(err);
        self.write_progress = 0;
    }

    pub fn close(self: *Connection) void {
        self.clearOutgoing();
        self.freeBody();
        if (self.fd >= 0) {
            fs.closeFd(self.fd);
            self.fd = -1;
        }
    }

    pub fn descriptor(self: *const Connection) c.fd_t {
        return self.fd;
    }

    fn failWrite(self: *Connection, err: anyerror) anyerror {
        if (err != error.Timeout and err != error.Canceled) {
            self.poisoned = true;
        } else if (self.write_progress != 0) {
            // The peer has seen part of this frame; the stream is desynchronized.
            self.poisoned = true;
        }
        return err;
    }

    fn writeAll(self: *Connection, bytes: []const u8, deadline: *const Deadline) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try waitReady(self.fd, c.POLL.OUT, deadline);
            const n = c.send(self.fd, bytes.ptr + offset, bytes.len - offset, native.send_flags);
            if (n < 0) {
                const e = libcErrno();
                switch (e) {
                    .AGAIN, .INTR => continue,
                    else => |other| return mapErrno(other),
                }
            }
            if (n == 0) return error.ConnectionClosed;
            offset += @intCast(n);
            self.write_progress += @intCast(n);
        }
    }

    /// Returns null on EOF; never returns WouldBlock (EAGAIN is retried after a
    /// bounded poll).
    fn readAvailable(self: *Connection, buf: []u8, deadline: *const Deadline) !?usize {
        while (true) {
            try waitReady(self.fd, c.POLL.IN, deadline);
            const n = c.read(self.fd, buf.ptr, buf.len);
            if (n > 0) return @intCast(n);
            if (n == 0) return null;
            const e = libcErrno();
            switch (e) {
                .AGAIN, .INTR => continue,
                else => |other| {
                    self.poisoned = true;
                    return mapErrno(other);
                },
            }
        }
    }

    fn clearFrame(self: *Connection) void {
        self.header_read = 0;
        self.declared = 0;
        self.body_read = 0;
        self.state = .header;
    }

    fn takeBody(self: *Connection) ![]u8 {
        const result = try self.allocator.dupe(u8, self.body.items);
        self.freeBody();
        return result;
    }

    fn appendBody(self: *Connection, bytes: []const u8) !void {
        const required = try std.math.add(usize, self.body.items.len, bytes.len);
        if (required > self.body.capacity) {
            var next: std.ArrayList(u8) = .empty;
            try next.ensureTotalCapacity(self.allocator, required);
            next.appendSliceAssumeCapacity(self.body.items);
            self.wipePendingBody();
            self.body.deinit(self.allocator);
            self.body = next;
        }
        self.body.appendSliceAssumeCapacity(bytes);
    }

    fn wipePendingBody(self: *Connection) void {
        // An incomplete login frame may already contain credential bytes, even
        // though no Request exists yet to run its normal secret cleanup.
        std.crypto.secureZero(u8, self.body.items);
    }

    fn freeBody(self: *Connection) void {
        self.wipePendingBody();
        self.body.deinit(self.allocator);
        self.body = .empty;
    }
};

// ---------------------------------------------------------------------------
// tests (offline; owned temp dirs only, no real config/session/env/network)
// ---------------------------------------------------------------------------

// Offline probe for `Wait.progress_fn`: counts ticks on the waiting thread and
// can either request cancellation or fail, mirroring the worker host pump.
