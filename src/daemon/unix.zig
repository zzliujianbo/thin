//! Linux AF_UNIX control transport for the optional Thin daemon.
//! 中文：守护模式的 Linux AF_UNIX 传输基础，只负责私有 runtime 目录、单实例锁、
//! 有界长度前缀帧与对端 UID 校验；不含业务 DTO、worker、TUI 或服务启动。
//!
//! Hard rules encoded here:
//! - sockets are SOCK_CLOEXEC | SOCK_NONBLOCK; every read/write is bounded by a
//!   caller deadline and a cancellation token, so an RPC thread never waits
//!   forever on a silent client.
//! - both ends verify SO_PEERCRED and compare the *real* kernel UID.
//! - the runtime directory is 0700 and the socket 0600; symlinks, foreign
//!   owners and permissive modes are rejected, never repaired.
//! - the single-instance lock is a fixed inode flock and is never unlinked; it
//!   records which directory it locked and which inode it locked, so it can
//!   never authorize deleting an entry in another directory.
//! - stale socket cleanup requires that held lock, verifies the directory and
//!   the lock inode through the directory fd, and only removes a socket owned by
//!   this UID inside this directory (no recursion).
//! - a socket is created and later stat/chmod/unlinked through the same
//!   directory fd (`/proc/self/fd/<dirfd>/<name>`), so a re-resolved or renamed
//!   path can neither redirect the bind nor hide the node this instance made.
//! - listener/directory cleanup only removes what this instance actually
//!   created, after re-checking dev/ino and owner.

const std = @import("std");
const c = std.c;
const linux = std.os.linux;
const fs = @import("../platform/filesystem.zig");
const protocol = @import("../core/protocol.zig");

/// Upper bound of a single frame payload (4-byte big-endian length prefix).
/// 中文：单帧载荷上限；业务展示快照仍需自行分页/裁剪到更小尺寸。
pub const max_frame_len: usize = 1024 * 1024;
/// Longest pathname that fits in `sockaddr_un.sun_path` (108 bytes incl. NUL).
pub const max_socket_path_len: usize = 107;
/// Longest accepted single path component (socket/lock file name).
pub const max_name_len: usize = 63;

const header_size: usize = 4;
const poll_slice_ms: i64 = 50;
const connect_retry_ms: i64 = 10;
/// AF_UNIX on Linux (std.os.linux.AF.UNIX).
const af_unix: u32 = 1;

/// Device+inode identity; inode numbers alone are not globally unique.
pub const Identity = struct {
    dev_major: u32,
    dev_minor: u32,
    ino: u64,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.dev_major == b.dev_major and a.dev_minor == b.dev_minor and a.ino == b.ino;
    }

    fn from(st: linux.Statx) Identity {
        return .{ .dev_major = st.dev_major, .dev_minor = st.dev_minor, .ino = st.ino };
    }
};

/// Kernel-reported peer credentials (`struct ucred`), never client-supplied.
pub const Credentials = struct {
    pid: u32,
    uid: u32,
    gid: u32,
};

const Ucred = extern struct {
    pid: c.pid_t,
    uid: c.uid_t,
    gid: c.gid_t,
};

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
fn libcErrno() linux.E {
    return @fromBackingInt(@intCast(c._errno().*));
}

fn libcFail() anyerror {
    return mapErrno(libcErrno());
}

fn mapErrno(e: linux.E) anyerror {
    return switch (e) {
        .SUCCESS => error.UnexpectedSystemError,
        .PERM, .ACCES => error.AccessDenied,
        .NOENT, .SRCH => error.FileNotFound,
        .EXIST => error.PathAlreadyExists,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .LOOP => error.SymlinkNotAllowed,
        .NAMETOOLONG => error.NameTooLong,
        .NOSPC => error.NoSpaceLeft,
        .NOTEMPTY => error.DirectoryNotEmpty,
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionReset,
        .CONNABORTED => error.ConnectionAborted,
        .PIPE => error.ConnectionClosed,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .NOTSOCK => error.NotASocket,
        .BADF => error.InvalidDescriptor,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.OutOfMemory,
        .NOBUFS => error.SystemResources,
        .OPNOTSUPP => error.OperationNotSupported,
        else => error.UnexpectedSystemError,
    };
}

// ---------------------------------------------------------------------------
// stat helpers (all libc; errno via libcErrno)
// ---------------------------------------------------------------------------

fn statAt(dir_fd: c.fd_t, path_z: [*:0]const u8, no_follow: bool) !linux.Statx {
    var result: linux.Statx = undefined;
    const flags: u32 = if (no_follow) linux.AT.SYMLINK_NOFOLLOW else 0;
    if (c.statx(dir_fd, path_z, flags, linux.STATX.BASIC_STATS, &result) != 0) return libcFail();
    return result;
}

fn statFd(fd: c.fd_t) !linux.Statx {
    var result: linux.Statx = undefined;
    if (c.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &result) != 0) return libcFail();
    return result;
}

fn isDir(mode: u16) bool {
    return mode & linux.S.IFMT == linux.S.IFDIR;
}

fn isSock(mode: u16) bool {
    return mode & linux.S.IFMT == linux.S.IFSOCK;
}

fn isReg(mode: u16) bool {
    return mode & linux.S.IFMT == linux.S.IFREG;
}

fn isLink(mode: u16) bool {
    return mode & linux.S.IFMT == linux.S.IFLNK;
}

fn perms(mode: u16) u16 {
    return mode & 0o777;
}

/// 0600/0700 socket permissions are fsck'd without following a swapped symlink
/// when the kernel offers fchmodat2; the caller re-verifies identity afterwards.
fn chmodNoFollow(fd: c.fd_t, path_z: [*:0]const u8, mode: u32) !void {
    const rc = linux.fchmodat2(fd, path_z, mode, linux.AT.SYMLINK_NOFOLLOW);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .NOSYS, .OPNOTSUPP, .INVAL => {},
        else => |e| return mapErrno(e),
    }
    // Pre-6.5 kernels: private 0700 directory plus the post-verification keep
    // this fallback honest.
    if (c.fchmodat(fd, path_z, mode, 0) != 0) return libcFail();
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

fn validatePrivateDir(st: linux.Statx, uid: u32) !void {
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

        const base_z = try allocator.dupeSentinel(u8, base_path, 0);
        defer allocator.free(base_z);
        const base_st = try statAt(linux.AT.FDCWD, base_z, true);
        try validatePrivateDir(base_st, uid);
        return createChild(allocator, base_path, "thin", uid);
    }

    /// Low-level: create/verify `<parent_path>/<name>` as a 0700 UID-owned real
    /// directory. The parent must be a real directory (its own mode/owner policy
    /// is the caller's decision, e.g. root-owned sticky /tmp).
    pub fn resolveUnder(allocator: std.mem.Allocator, parent_path: []const u8, name: []const u8, uid: u32) !Directory {
        try validateName(name);
        if (parent_path.len == 0 or !std.fs.path.isAbsolute(parent_path)) return error.InvalidPath;
        if (std.mem.findScalar(u8, parent_path, 0) != null) return error.InvalidPath;
        if (parent_path.len + 1 + name.len > max_socket_path_len) return error.NameTooLong;

        const parent_z = try allocator.dupeSentinel(u8, parent_path, 0);
        defer allocator.free(parent_z);
        const parent_st = try statAt(linux.AT.FDCWD, parent_z, true);
        if (isLink(parent_st.mode)) return error.SymlinkNotAllowed;
        if (!isDir(parent_st.mode)) return error.NotDirectory;
        return createChild(allocator, parent_path, name, uid);
    }

    /// Fallback when `$XDG_RUNTIME_DIR` is unset: `/tmp/thin-<uid>`.
    pub fn resolveFallback(allocator: std.mem.Allocator, uid: u32) !Directory {
        const tmp_st = try statAt(linux.AT.FDCWD, "/tmp", true);
        if (isLink(tmp_st.mode) or !isDir(tmp_st.mode)) return error.InsecureRuntimeBase;
        if (tmp_st.uid != 0) return error.InsecureRuntimeBase;
        if (tmp_st.mode & linux.S.ISVTX == 0) return error.InsecureRuntimeBase;
        if (perms(tmp_st.mode) & 0o002 == 0) return error.InsecureRuntimeBase;

        var buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "thin-{d}", .{uid});
        return resolveUnder(allocator, "/tmp", name, uid);
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
        const path_z = try self.allocator.dupeSentinel(u8, self.path, 0);
        defer self.allocator.free(path_z);
        const st = statAt(linux.AT.FDCWD, path_z, true) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (!isDir(st.mode)) return error.NotDirectory;
        if (st.uid != self.uid) return error.NotOwned;
        if (!Identity.from(st).eql(self.identity)) return error.IdentityChanged;
        if (c.rmdir(path_z) != 0) return libcFail();
    }
};

fn createChild(allocator: std.mem.Allocator, parent_path: []const u8, name: []const u8, uid: u32) !Directory {
    const parent_z = try allocator.dupeSentinel(u8, parent_path, 0);
    defer allocator.free(parent_z);
    const parent_fd = try fs.openDirectory(linux.AT.FDCWD, parent_z);
    defer fs.closeFd(parent_fd);

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
    if (!Identity.from(opened).eql(Identity.from(st))) return error.IdentityChanged;

    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent_path, name });
    return .{
        .allocator = allocator,
        .fd = fd,
        .path = path,
        .uid = uid,
        .identity = Identity.from(opened),
        .created = created,
    };
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
        const fd = fs.linux.openat(
            dir.fd,
            name_z,
            2 | fs.linux.create | fs.linux.nofollow | fs.linux.cloexec | fs.linux.nonblock,
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

        if (fs.linux.flock(fd, 2 | 4) != 0) {
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
        _ = fs.linux.flock(self.fd, 8); // LOCK_UN; the inode stays on disk.
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

fn socketFd() !c.fd_t {
    const rc = linux.socket(af_unix, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => |e| return mapErrno(e),
    }
}

fn sockAddr(path: []const u8) linux.sockaddr.un {
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

fn addrLen(path: []const u8) c.socklen_t {
    return @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len);
}

/// Kernel SO_PEERCRED lookup; the returned UID is authoritative for both ends.
pub fn socketCredentials(fd: c.fd_t) !Credentials {
    var cred: Ucred = undefined;
    var len: c.socklen_t = @sizeOf(Ucred);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |e| return mapErrno(e),
    }
    if (len != @sizeOf(Ucred)) return error.PeerCredentialsUnavailable;
    if (cred.pid <= 0) return error.PeerCredentialsUnavailable;
    return .{ .pid = @intCast(cred.pid), .uid = cred.uid, .gid = cred.gid };
}

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

/// `/proc/self/fd/<dirfd>/<name>`: binding this path makes the kernel create the
/// socket node inside the directory the descriptor refers to, so the node never
/// depends on re-resolving (or re-validating) the absolute directory path.
fn fdAnchoredBindPath(allocator: std.mem.Allocator, dir_fd: c.fd_t, name_z: [*:0]const u8) ![:0]u8 {
    const joined = try std.fmt.allocPrint(allocator, "/proc/self/fd/{d}/{s}", .{ dir_fd, std.mem.span(name_z) });
    defer allocator.free(joined);
    return allocator.dupeSentinel(u8, joined, 0);
}

/// The exported socket path stays the real directory path, so it must still name
/// the very directory `dir.fd` refers to; a renamed or replaced directory would
/// publish a path that leads elsewhere.
fn verifyDirectoryPath(dir: *const Directory) !void {
    const now = try statFd(dir.fd);
    if (!isDir(now.mode)) return error.NotDirectory;
    if (!Identity.from(now).eql(dir.identity)) return error.DirectoryMoved;

    const path_z = try dir.allocator.dupeSentinel(u8, dir.path, 0);
    defer dir.allocator.free(path_z);
    const on_path = statAt(linux.AT.FDCWD, path_z, true) catch |err| switch (err) {
        error.FileNotFound => return error.DirectoryMoved,
        else => return err,
    };
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
        if (revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0) return;
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

        const fd = try socketFd();
        errdefer fs.closeFd(fd);

        const bind_path = try fdAnchoredBindPath(allocator, dir.fd, name_z);
        defer allocator.free(bind_path);
        var addr = sockAddr(bind_path);
        switch (linux.errno(linux.bind(fd, @ptrCast(&addr), addrLen(bind_path)))) {
            .SUCCESS => {},
            // The directory fd itself is open, so ENOENT/ENOTDIR here means the
            // fd-anchored namespace is missing (no procfs), not a missing
            // directory: refuse rather than fall back to a path-based bind.
            .NOENT, .NOTDIR => return error.FdAnchoredPathUnavailable,
            else => |e| return mapErrno(e),
        }

        // bind() succeeded, so the entry inside this directory is the node this
        // call created (an existing entry fails with EADDRINUSE above; the fd's
        // own fstat identity is the sockfs inode, not the filesystem node). Take
        // the entry's identity and own the cleanup before any further fallible
        // step, so a later chmod/listen/dup failure removes our own socket and
        // never a foreign entry.
        const identity = Identity.from(try statAt(dir.fd, name_z, true));
        errdefer unlinkIfMatches(dir.fd, name_z, identity, dir.uid);
        if (fault == .after_bind) return error.InjectedBindFailure;

        try ensureSocketFile(dir.fd, name_z, dir.uid, identity);

        const listen_rc = linux.listen(fd, std.math.clamp(options.backlog, 1, 4096));
        switch (linux.errno(listen_rc)) {
            .SUCCESS => {},
            else => |e| return mapErrno(e),
        }

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
            try waitReady(self.fd, linux.POLL.IN, &deadline);
            const rc = linux.accept4(self.fd, null, null, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    const fd: c.fd_t = @intCast(rc);
                    errdefer fs.closeFd(fd);
                    const peer = try socketCredentials(fd);
                    if (peer.uid != self.uid) return error.PeerUidMismatch;
                    return Connection.init(self.allocator, fd, peer);
                },
                .AGAIN, .INTR, .CONNABORTED => continue,
                else => |e| return mapErrno(e),
            }
        }
    }

    /// Single nonblocking accept attempt. A quiet listener never waits on the
    /// owner thread; caller readiness polling owns scheduling and deadlines.
    pub fn acceptStep(self: *Listener) !?Connection {
        const rc = linux.accept4(self.fd, null, null, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const fd: c.fd_t = @intCast(rc);
                errdefer fs.closeFd(fd);
                const peer = try socketCredentials(fd);
                if (peer.uid != self.uid) return error.PeerUidMismatch;
                return Connection.init(self.allocator, fd, peer);
            },
            .AGAIN, .INTR, .CONNABORTED => return null,
            else => |err| return mapErrno(err),
        }
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
    var addr = sockAddr(path);
    while (true) {
        try deadline.tick();
        const rc = linux.connect(fd, @ptrCast(&addr), addrLen(path));
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            // Nonblocking AF_UNIX connect is refused while the backlog is full;
            // retry within the caller's deadline rather than spinning.
            .AGAIN, .INPROGRESS, .ALREADY => {},
            else => |e| return mapErrno(e),
        }
        try sleepSlice(deadline);
    }
}

/// Connect to an existing daemon socket and verify SO_PEERCRED. The path entry
/// must be a real socket owned by `expected_uid`; symlinks are refused.
pub fn connect(allocator: std.mem.Allocator, path: []const u8, expected_uid: u32, wait: Wait) !Connection {
    try validateSocketPath(path);

    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    const st = try statAt(linux.AT.FDCWD, path_z, true);
    if (isLink(st.mode)) return error.SymlinkNotAllowed;
    if (!isSock(st.mode)) return error.NotASocket;
    if (st.uid != expected_uid) return error.NotOwned;

    const fd = try socketFd();
    errdefer fs.closeFd(fd);

    var deadline = Deadline.init(wait);
    try connectPath(fd, path, &deadline);

    const peer = try socketCredentials(fd);
    if (peer.uid != expected_uid) return error.PeerUidMismatch;
    return Connection.init(allocator, fd, peer);
}

/// Convenience: join the directory and connect, trusting only `dir.uid`.
pub fn connectDirectory(allocator: std.mem.Allocator, dir: *const Directory, name: []const u8, wait: Wait) !Connection {
    const path = try dir.join(allocator, name);
    defer allocator.free(path);
    return connect(allocator, path, dir.uid, wait);
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
    body: []u8 = &.{},
    body_read: usize = 0,
    write_progress: usize = 0,
    poisoned: bool = false,
    /// Owned header+payload for the step writer. Exactly one frame may be
    /// pending; synchronous writes cannot interleave with it.
    outgoing: []u8 = &.{},
    outgoing_offset: usize = 0,

    pub const ReadStep = union(enum) { pending, eof, frame: []u8 };
    pub const step_bytes: usize = 64 * 1024;

    /// Takes ownership of `fd`; peer must already be verified.
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

        if (self.body.len != self.declared) self.body = try self.allocator.alloc(u8, self.declared);
        while (self.body_read < self.declared) {
            const maybe = try self.readAvailable(self.body[self.body_read..], &deadline);
            const n = maybe orelse {
                self.freeBody();
                self.clearFrame();
                self.poisoned = true;
                return error.TruncatedFrame;
            };
            self.body_read += n;
        }

        const frame = self.body;
        self.body = &.{};
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
            self.declared = std.mem.readInt(u32, &self.header, .big);
            if (self.declared > max_frame_len) {
                self.poisoned = true;
                return error.FrameTooLarge;
            }
            self.state = .body;
        }
        if (self.body.len != self.declared) self.body = try self.allocator.alloc(u8, self.declared);
        if (self.body_read < self.declared) {
            const end = @min(self.declared, self.body_read + step_bytes);
            const n = self.receiveStep(self.body[self.body_read..end]) catch |err| switch (err) {
                error.WouldBlock => return .pending,
                else => return err,
            };
            if (n == 0) {
                self.poisoned = true;
                return error.TruncatedFrame;
            }
            self.body_read += n;
            if (self.body_read < self.declared) return .pending;
        }
        const frame = self.body;
        self.body = &.{};
        self.clearFrame();
        return .{ .frame = frame };
    }

    fn receiveStep(self: *Connection, bytes: []u8) !usize {
        const n = c.recv(self.fd, bytes.ptr, bytes.len, linux.MSG.DONTWAIT);
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
        const frame = try self.allocator.alloc(u8, header_size + payload.len);
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
        const n = c.send(self.fd, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT);
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
            try waitReady(self.fd, linux.POLL.OUT, deadline);
            const n = c.send(self.fd, bytes.ptr + offset, bytes.len - offset, linux.MSG.NOSIGNAL);
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
            try waitReady(self.fd, linux.POLL.IN, deadline);
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

    fn wipePendingBody(self: *Connection) void {
        // An incomplete login frame may already contain credential bytes, even
        // though no Request exists yet to run its normal secret cleanup.
        std.crypto.secureZero(u8, self.body);
    }

    fn freeBody(self: *Connection) void {
        self.wipePendingBody();
        if (self.body.len != 0) self.allocator.free(self.body);
        self.body = &.{};
    }
};

// ---------------------------------------------------------------------------
// tests (offline; owned temp dirs only, no real config/session/env/network)
// ---------------------------------------------------------------------------

const test_peer: Credentials = .{ .pid = 0, .uid = 0, .gid = 0 };

fn testWait() Wait {
    return .{ .io = std.testing.io, .timeout_ms = 1000 };
}

fn testPair(allocator: std.mem.Allocator) !struct { a: Connection, b: Connection } {
    var fds: [2]c.fd_t = undefined;
    const rc = linux.socketpair(
        af_unix,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
        &fds,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    return .{
        .a = Connection.init(allocator, fds[0], test_peer),
        .b = Connection.init(allocator, fds[1], test_peer),
    };
}

fn sendAll(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.send(fd, bytes.ptr + offset, bytes.len - offset, linux.MSG.NOSIGNAL);
        try std.testing.expect(n > 0);
        offset += @intCast(n);
    }
}

fn testPrivateDir(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) !Directory {
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return Directory.resolveUnder(allocator, buf[0..n], "rt", @intCast(c.geteuid()));
}

fn testParent(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(std.testing.io, buf);
    return buf[0..n];
}

fn testPath(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
    defer allocator.free(path);
    return allocator.dupeSentinel(u8, path, 0);
}

test "partial frame storage is wiped before discard and close is idempotent" {
    var conn = Connection.init(std.testing.allocator, -1, test_peer);
    defer conn.close();
    conn.body = try std.testing.allocator.dupe(u8, "partial-login-credential");
    conn.body_read = conn.body.len;
    conn.wipePendingBody();
    for (conn.body) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    conn.close();
    try std.testing.expectEqual(@as(usize, 0), conn.body.len);
    conn.close();
}

test "step reader preserves partial header and body without waiting" {
    var pair = try testPair(std.testing.allocator);
    defer pair.a.close();
    defer pair.b.close();
    try std.testing.expect((try pair.a.readStep()) == .pending);
    try sendAll(pair.b.fd, &.{ 0, 0 });
    try std.testing.expect((try pair.a.readStep()) == .pending);
    try std.testing.expectEqual(@as(usize, 2), pair.a.header_read);
    try sendAll(pair.b.fd, &.{ 0, 3, 'a' });
    try std.testing.expect((try pair.a.readStep()) == .pending);
    try std.testing.expectEqual(@as(usize, 1), pair.a.body_read);
    try sendAll(pair.b.fd, "bc");
    const frame = (try pair.a.readStep()).frame;
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqualStrings("abc", frame);
    try sendAll(pair.b.fd, &.{ 0, 0, 0, 0 });
    const empty = (try pair.a.readStep()).frame;
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    pair.b.close();
    try std.testing.expect((try pair.a.readStep()) == .eof);
}

test "step reader rejects truncated and oversized frames" {
    for ([_][]const u8{ &.{0}, &.{ 0, 0, 0, 2, 'x' }, &.{ 0xff, 0xff, 0xff, 0xff } }, 0..) |raw, index| {
        var pair = try testPair(std.testing.allocator);
        defer pair.a.close();
        defer pair.b.close();
        try sendAll(pair.b.fd, raw);
        pair.b.close();
        if (index == 2) {
            try std.testing.expectError(error.FrameTooLarge, pair.a.readStep());
        } else {
            try std.testing.expect((try pair.a.readStep()) == .pending);
            try std.testing.expectError(error.TruncatedFrame, pair.a.readStep());
        }
        try std.testing.expectError(error.StreamPoisoned, pair.a.readStep());
    }
}

test "step writer backpressure preserves the exact frame and another connection progresses" {
    const a = std.testing.allocator;
    var slow = try testPair(a);
    defer slow.a.close();
    defer slow.b.close();
    var fast = try testPair(a);
    defer fast.a.close();
    defer fast.b.close();
    const payload = try a.alloc(u8, max_frame_len);
    defer a.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @intCast(index % 251);
    try slow.a.queueFrame(payload);
    try std.testing.expectError(error.WriteInProgress, slow.a.queueFrame("interleave"));
    try std.testing.expectError(error.WriteInProgress, slow.a.writeFrame("interleave", testWait()));
    // Do not read the peer: bounded steps eventually encounter EAGAIN.
    for (0..64) |_| _ = try slow.a.writeStep();
    try std.testing.expect(slow.a.writePending());
    try std.testing.expect(slow.a.outgoing_offset > 0);
    const stopped_at = slow.a.outgoing_offset;
    try std.testing.expect(!try slow.a.writeStep());
    try std.testing.expectEqual(stopped_at, slow.a.outgoing_offset);
    try fast.a.queueFrame("control-reply");
    try std.testing.expect(try fast.a.writeStep());
    const quick = (try fast.b.readStep()).frame;
    defer a.free(quick);
    try std.testing.expectEqualStrings("control-reply", quick);
    var received = false;
    for (0..128) |_| {
        _ = try slow.a.writeStep();
        switch (try slow.b.readStep()) {
            .frame => |frame| {
                defer a.free(frame);
                try std.testing.expectEqualSlices(u8, payload, frame);
                received = true;
                break;
            },
            .pending => {},
            .eof => return error.UnexpectedEof,
        }
    }
    try std.testing.expect(received);
    try std.testing.expect(!slow.a.poisoned);
    try std.testing.expect(!slow.a.writePending());
    try slow.a.queueFrame("next");
    try std.testing.expect(try slow.a.writeStep());
    const next = (try slow.b.readStep()).frame;
    defer a.free(next);
    try std.testing.expectEqualStrings("next", next);
}

test "frame roundtrip and clean EOF" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();
    const wait = testWait();

    try b.writeFrame("hello", wait);
    const frame = (try a.readFrame(wait)).?;
    defer allocator.free(frame);
    try std.testing.expectEqualStrings("hello", frame);

    // A zero-length frame stays distinguishable from EOF.
    try b.writeFrame("", wait);
    const empty = (try a.readFrame(wait)).?;
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    b.close();
    try std.testing.expect((try a.readFrame(wait)) == null);
}

test "read timeout preserves a partial frame" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();
    const short: Wait = .{ .io = std.testing.io, .timeout_ms = 20 };

    var header: [header_size]u8 = undefined;
    std.mem.writeInt(u32, &header, 5, .big);
    try sendAll(b.descriptor(), header[0..2]);
    try std.testing.expectError(error.Timeout, a.readFrame(short));

    // The consumed prefix is retained; the frame completes on the next call.
    try sendAll(b.descriptor(), header[2..4]);
    try sendAll(b.descriptor(), "hello");
    const frame = (try a.readFrame(testWait())).?;
    defer allocator.free(frame);
    try std.testing.expectEqualStrings("hello", frame);
}

/// Offline probe for `Wait.progress_fn`: counts ticks on the waiting thread and
/// can either request cancellation or fail, mirroring the worker host pump.
const TestProgress = struct {
    ticks: usize = 0,
    cancel_after: usize = std.math.maxInt(usize),
    fail_after: usize = std.math.maxInt(usize),
    token: ?*const protocol.Cancellation = null,

    fn run(ctx: ?*anyopaque) anyerror!void {
        const self: *TestProgress = @ptrCast(@alignCast(ctx orelse return error.UnexpectedSystemError));
        self.ticks += 1;
        if (self.ticks >= self.fail_after) return error.Canceled;
        if (self.ticks >= self.cancel_after) {
            if (self.token) |token| @constCast(token).cancel();
        }
    }
};

test "wait progress ticks while no frame arrives and can cancel" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();

    var token: protocol.Cancellation = .{};
    var probe: TestProgress = .{ .cancel_after = 3, .token = &token };
    const wait: Wait = .{
        .io = std.testing.io,
        .timeout_ms = 2000,
        .cancel = &token,
        .progress_context = &probe,
        .progress_fn = TestProgress.run,
    };

    // No bytes are ever sent: the wait stays silent but the pump keeps ticking.
    try std.testing.expectError(error.Canceled, a.readFrame(wait));
    try std.testing.expect(probe.ticks >= 3);
    try std.testing.expect(token.isRequested());
    // Canceling before any byte preserves the (still empty) partial frame.
    try std.testing.expect(!a.poisoned);
}

test "wait progress errors abort the wait unchanged" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();

    var probe: TestProgress = .{ .fail_after = 2 };
    const wait: Wait = .{
        .io = std.testing.io,
        .timeout_ms = 2000,
        .progress_context = &probe,
        .progress_fn = TestProgress.run,
    };
    try std.testing.expectError(error.Canceled, a.readFrame(wait));
    try std.testing.expectEqual(@as(usize, 2), probe.ticks);
}

test "wait progress ticks do not extend the original deadline" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();

    var probe: TestProgress = .{};
    const start = std.Io.Clock.awake.now(std.testing.io);
    const wait: Wait = .{
        .io = std.testing.io,
        .timeout_ms = 150,
        .progress_context = &probe,
        .progress_fn = TestProgress.run,
    };
    try std.testing.expectError(error.Timeout, a.readFrame(wait));
    const elapsed = start.untilNow(std.testing.io, .awake).toMilliseconds();

    // Several progress ticks happen inside one time budget...
    try std.testing.expect(probe.ticks >= 2);
    // ...and the wait still ends on the original deadline instead of a re-based one.
    try std.testing.expect(elapsed >= 120);
    try std.testing.expect(elapsed < 700);
}

test "truncated frame and poisoned stream" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();

    try sendAll(b.descriptor(), "\x00\x00");
    b.close();
    try std.testing.expectError(error.TruncatedFrame, a.readFrame(testWait()));
    try std.testing.expectError(error.StreamPoisoned, a.readFrame(testWait()));
}

test "declared length above the transport bound is rejected" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();

    var header: [header_size]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(max_frame_len + 1), .big);
    try sendAll(b.descriptor(), &header);
    try std.testing.expectError(error.FrameTooLarge, a.readFrame(testWait()));
}

test "oversized write is refused before any byte is written" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();
    const wait = testWait();

    const payload = try allocator.alloc(u8, max_frame_len + 1);
    defer allocator.free(payload);
    @memset(payload, 'x');
    try std.testing.expectError(error.FrameTooLarge, b.writeFrame(payload, wait));

    // The stream is untouched and still usable.
    try b.writeFrame("ok", wait);
    const frame = (try a.readFrame(wait)).?;
    defer allocator.free(frame);
    try std.testing.expectEqualStrings("ok", frame);
}

test "cancellation interrupts a pending read and accept" {
    const allocator = std.testing.allocator;
    const pair = try testPair(allocator);
    var a = pair.a;
    defer a.close();
    var b = pair.b;
    defer b.close();

    var token: protocol.Cancellation = .{};
    token.cancel();
    try std.testing.expectError(
        error.Canceled,
        a.readFrame(.{ .io = std.testing.io, .timeout_ms = 1000, .cancel = &token }),
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();
    var listener = try Listener.bind(allocator, &dir, "c.sock", .{});
    defer listener.deinit();
    try std.testing.expectError(
        error.Canceled,
        listener.accept(.{ .io = std.testing.io, .timeout_ms = 1000, .cancel = &token }),
    );
}

test "private directory requires 0700, same UID, and no symlink" {
    const allocator = std.testing.allocator;
    const me: u32 = @intCast(c.geteuid());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const parent = buf[0..n];
    const parent_z = try allocator.dupeSentinel(u8, parent, 0);
    defer allocator.free(parent_z);

    // tmpDir is created 0755: not a private runtime directory.
    try std.testing.expectError(error.InsecurePermissions, Directory.resolveBase(allocator, parent, me));
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(parent_z, 0o700));

    var dir = try Directory.resolveBase(allocator, parent, me);
    defer dir.deinit();
    try std.testing.expect(dir.created);
    const child_z = try allocator.dupeSentinel(u8, dir.path, 0);
    defer allocator.free(child_z);
    const child_st = try statAt(linux.AT.FDCWD, child_z, true);
    try std.testing.expect(isDir(child_st.mode));
    try std.testing.expectEqual(@as(u16, 0o700), perms(child_st.mode));

    // Wrong expected owner: the leaf exists but is not owned by that UID.
    try std.testing.expectError(error.NotOwned, Directory.resolveUnder(allocator, parent, "foreign", me + 1));

    // A symlinked base is refused rather than followed.
    const link_z = try testPath(allocator, parent, "link");
    defer allocator.free(link_z);
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("rt", linux.AT.FDCWD, link_z));
    try std.testing.expectError(error.SymlinkNotAllowed, Directory.resolveBase(allocator, link_z, me));
}

test "socket names and paths are validated" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    try std.testing.expectError(error.InvalidName, dir.join(allocator, "a/b"));
    try std.testing.expectError(error.InvalidName, dir.join(allocator, ".."));
    try std.testing.expectError(error.InvalidName, dir.join(allocator, ""));

    // room = max name length that still overflows the sockaddr_un path.
    const room: usize = max_socket_path_len - dir.path.len;
    if (room <= max_name_len) {
        var name_buf: [max_name_len + 1]u8 = undefined;
        @memset(&name_buf, 'x');
        try std.testing.expectError(error.NameTooLong, dir.join(allocator, name_buf[0..room]));
        const ok = try dir.join(allocator, name_buf[0 .. room - 1]);
        defer allocator.free(ok);
        try std.testing.expectEqual(max_socket_path_len, ok.len);
    }
}

test "created directory cleanup is empty-only and identity checked" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();
    try std.testing.expect(dir.created);

    const keep_fd = fs.linux.openat(dir.fd, "keep", 2 | fs.linux.create | fs.linux.exclusive | fs.linux.cloexec, 0o600);
    try std.testing.expect(keep_fd >= 0);
    fs.closeFd(keep_fd);
    try std.testing.expectError(error.DirectoryNotEmpty, dir.removeIfEmpty());

    try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(dir.fd, "keep", 0));
    const path_copy = try allocator.dupeSentinel(u8, dir.path, 0);
    defer allocator.free(path_copy);
    try dir.removeIfEmpty();
    try std.testing.expectError(error.FileNotFound, statAt(linux.AT.FDCWD, path_copy, true));
    // Idempotent when the directory is already gone.
    try dir.removeIfEmpty();
}

test "lock is exclusive, keeps one fixed inode, and is never unlinked" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    var first = try Lock.acquire(allocator, &dir, "daemon.lock");
    try std.testing.expect(first.isHeld());
    try std.testing.expectError(error.AlreadyRunning, Lock.acquire(allocator, &dir, "daemon.lock"));

    const name_z = try allocator.dupeSentinel(u8, "daemon.lock", 0);
    defer allocator.free(name_z);
    const before = try statAt(dir.fd, name_z, true);
    try std.testing.expect(isReg(before.mode));
    try std.testing.expectEqual(@as(u16, 0o600), perms(before.mode));

    first.release();
    try std.testing.expect(!first.isHeld());

    var second = try Lock.acquire(allocator, &dir, "daemon.lock");
    const after = try statAt(dir.fd, name_z, true);
    try std.testing.expectEqual(before.ino, after.ino);
    try std.testing.expectEqual(before.dev_major, after.dev_major);
    second.release();

    const still = try statAt(dir.fd, name_z, true);
    try std.testing.expect(isReg(still.mode));
}

test "lock refuses symlinked and permissive lock files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    const link_z = try allocator.dupeSentinel(u8, "link.lock", 0);
    defer allocator.free(link_z);
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("daemon.lock", dir.fd, link_z));

    const loose_fd = fs.linux.openat(
        dir.fd,
        "loose.lock",
        2 | fs.linux.create | fs.linux.exclusive | fs.linux.cloexec,
        0o600,
    );
    try std.testing.expect(loose_fd >= 0);
    try std.testing.expectEqual(@as(c_int, 0), c.fchmod(loose_fd, 0o644));
    fs.closeFd(loose_fd);

    // O_NOFOLLOW turns the symlink into ELOOP at open time.
    try std.testing.expectError(error.SymlinkNotAllowed, Lock.acquire(allocator, &dir, "link.lock"));
    try std.testing.expectError(error.InsecurePermissions, Lock.acquire(allocator, &dir, "loose.lock"));
}

test "listener binds a 0600 socket and verifies peer UID on both ends" {
    const allocator = std.testing.allocator;
    const me: u32 = @intCast(c.geteuid());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    var lock = try Lock.acquire(allocator, &dir, "daemon.lock");
    defer lock.release();
    var listener = try Listener.bind(allocator, &dir, "daemon.sock", .{ .lock = &lock });
    defer listener.deinit();

    const name_z = try allocator.dupeSentinel(u8, "daemon.sock", 0);
    defer allocator.free(name_z);
    const st = try statAt(dir.fd, name_z, true);
    try std.testing.expect(isSock(st.mode));
    try std.testing.expectEqual(@as(u16, 0o600), perms(st.mode));
    try std.testing.expectEqual(me, st.uid);

    const wait = testWait();
    var client = try connect(allocator, listener.socketPath(), me, wait);
    defer client.close();
    var server = try listener.accept(wait);
    defer server.close();

    try std.testing.expectEqual(me, client.peer.uid);
    try std.testing.expectEqual(me, server.peer.uid);

    try client.writeFrame("ping", wait);
    const frame = (try server.readFrame(wait)).?;
    defer allocator.free(frame);
    try std.testing.expectEqualStrings("ping", frame);

    // A client expecting another UID is refused by the path prevalidation:
    // `connect` stats the socket node before dialling, so the wrong owner is
    // rejected as NotOwned and SO_PEERCRED is never consulted. (A genuine
    // PeerUidMismatch needs a peer of a different UID behind a node this UID
    // owns, which an unprivileged owned fixture cannot produce.)
    try std.testing.expectError(error.NotOwned, connect(allocator, listener.socketPath(), me + 1, wait));
}

test "listener accept honors timeout and cancellation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();
    var listener = try Listener.bind(allocator, &dir, "idle.sock", .{});
    defer listener.deinit();

    try std.testing.expectError(
        error.Timeout,
        listener.accept(.{ .io = std.testing.io, .timeout_ms = 30 }),
    );
    var token: protocol.Cancellation = .{};
    token.cancel();
    try std.testing.expectError(
        error.Canceled,
        listener.accept(.{ .io = std.testing.io, .timeout_ms = 1000, .cancel = &token }),
    );
}

test "listener cleanup removes only its own socket inode" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    const name_z = try allocator.dupeSentinel(u8, "owned.sock", 0);
    defer allocator.free(name_z);

    // Normal cleanup removes the socket this instance bound.
    var first = try Listener.bind(allocator, &dir, "owned.sock", .{});
    first.deinit();
    try std.testing.expectError(error.FileNotFound, statAt(dir.fd, name_z, true));

    // If the entry was replaced by another inode, cleanup leaves it alone.
    var second = try Listener.bind(allocator, &dir, "owned.sock", .{});
    try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(dir.fd, name_z, 0));
    const other_fd = fs.linux.openat(
        dir.fd,
        name_z,
        2 | fs.linux.create | fs.linux.exclusive | fs.linux.cloexec,
        0o600,
    );
    try std.testing.expect(other_fd >= 0);
    fs.closeFd(other_fd);
    second.deinit();
    const replaced = try statAt(dir.fd, name_z, true);
    try std.testing.expect(isReg(replaced.mode));
}

test "stale socket cleanup requires the lock and the owner UID" {
    const allocator = std.testing.allocator;
    const me: u32 = @intCast(c.geteuid());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    var lock = try Lock.acquire(allocator, &dir, "daemon.lock");
    defer lock.release();
    var listener = try Listener.bind(allocator, &dir, "stale.sock", .{ .lock = &lock });
    defer listener.deinit();
    listener.close(); // keep the socket inode, drop the listener fd

    // A released lock is not proof of ownership.
    var released = try Lock.acquire(allocator, &dir, "other.lock");
    released.release();
    try std.testing.expectError(error.LockNotHeld, removeStaleSocket(&released, &dir, "stale.sock"));

    try std.testing.expect(try removeStaleSocket(&lock, &dir, "stale.sock"));
    try std.testing.expect(!(try removeStaleSocket(&lock, &dir, "stale.sock")));

    // Regular files are never removed.
    const file_fd = fs.linux.openat(
        dir.fd,
        "file.sock",
        2 | fs.linux.create | fs.linux.exclusive | fs.linux.cloexec,
        0o600,
    );
    try std.testing.expect(file_fd >= 0);
    fs.closeFd(file_fd);
    try std.testing.expectError(error.NotASocket, removeStaleSocket(&lock, &dir, "file.sock"));

    // Nor are symlinks.
    const link_z = try allocator.dupeSentinel(u8, "link.sock", 0);
    defer allocator.free(link_z);
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat("stale.sock", dir.fd, link_z));
    try std.testing.expectError(error.SymlinkNotAllowed, removeStaleSocket(&lock, &dir, "link.sock"));

    // A UID mismatch between lock and directory is refused outright.
    var foreign_lock: Lock = lock;
    foreign_lock.uid = me + 1;
    foreign_lock.held = true;
    try std.testing.expectError(error.UidMismatch, removeStaleSocket(&foreign_lock, &dir, "stale.sock"));
}

test "stale cleanup requires the lock taken in this very directory" {
    const allocator = std.testing.allocator;
    const me: u32 = @intCast(c.geteuid());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const parent = try testParent(&tmp, &buf);

    var dir_a = try Directory.resolveUnder(allocator, parent, "a", me);
    defer dir_a.deinit();
    var dir_b = try Directory.resolveUnder(allocator, parent, "b", me);
    defer dir_b.deinit();

    // A genuinely held lock, but of the other directory.
    var lock_a = try Lock.acquire(allocator, &dir_a, "daemon.lock");
    defer lock_a.release();
    try std.testing.expect(lock_a.isHeld());

    // The other directory holds a live socket of this same UID.
    var listener_b = try Listener.bind(allocator, &dir_b, "active.sock", .{});
    defer listener_b.deinit();
    const name_z = try allocator.dupeSentinel(u8, "active.sock", 0);
    defer allocator.free(name_z);

    try std.testing.expectError(error.DirectoryMismatch, removeStaleSocket(&lock_a, &dir_b, "active.sock"));
    const after = try statAt(dir_b.fd, name_z, true);
    try std.testing.expect(Identity.from(after).eql(listener_b.socketIdentity()));

    // The bind path refuses the same way and deletes nothing.
    try std.testing.expectError(
        error.DirectoryMismatch,
        Listener.bind(allocator, &dir_b, "active.sock", .{ .lock = &lock_a }),
    );
    const still = try statAt(dir_b.fd, name_z, true);
    try std.testing.expect(Identity.from(still).eql(listener_b.socketIdentity()));

    // The same lock still authorizes cleanup in the directory it locked.
    var stale = try Listener.bind(allocator, &dir_a, "stale.sock", .{ .lock = &lock_a });
    defer stale.deinit();
    stale.close();
    try std.testing.expect(try removeStaleSocket(&lock_a, &dir_a, "stale.sock"));
}

test "stale cleanup refuses a lock whose file inode was replaced" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    var lock = try Lock.acquire(allocator, &dir, "daemon.lock");
    defer lock.release();
    var listener = try Listener.bind(allocator, &dir, "stale.sock", .{ .lock = &lock });
    defer listener.deinit();
    listener.close();

    const lock_z = try allocator.dupeSentinel(u8, "daemon.lock", 0);
    defer allocator.free(lock_z);
    const sock_z = try allocator.dupeSentinel(u8, "stale.sock", 0);
    defer allocator.free(sock_z);

    // Replace the lock path with a fresh inode while the flock stays held.
    try std.testing.expectEqual(@as(c_int, 0), c.unlinkat(dir.fd, lock_z, 0));
    const other_fd = fs.linux.openat(
        dir.fd,
        lock_z,
        2 | fs.linux.create | fs.linux.exclusive | fs.linux.cloexec,
        0o600,
    );
    try std.testing.expect(other_fd >= 0);
    fs.closeFd(other_fd);

    try std.testing.expectError(error.LockIdentityChanged, removeStaleSocket(&lock, &dir, "stale.sock"));
    const kept = try statAt(dir.fd, sock_z, true);
    try std.testing.expect(Identity.from(kept).eql(listener.socketIdentity()));
    try std.testing.expectError(
        error.LockIdentityChanged,
        Listener.bind(allocator, &dir, "stale.sock", .{ .lock = &lock }),
    );
    const kept_again = try statAt(dir.fd, sock_z, true);
    try std.testing.expect(Identity.from(kept_again).eql(listener.socketIdentity()));
}

test "a failed bind owns and removes only the socket it created" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    const worker_z = try allocator.dupeSentinel(u8, "worker.sock", 0);
    defer allocator.free(worker_z);

    // No lock: a unique worker name binds, an occupied one is refused and the
    // existing entry is left untouched.
    var worker = try Listener.bind(allocator, &dir, "worker.sock", .{});
    defer worker.deinit();
    const before = try statAt(dir.fd, worker_z, true);
    try std.testing.expectError(error.AddressInUse, Listener.bind(allocator, &dir, "worker.sock", .{}));
    const after = try statAt(dir.fd, worker_z, true);
    try std.testing.expect(Identity.from(before).eql(Identity.from(after)));
    try std.testing.expect(Identity.from(after).eql(worker.socketIdentity()));

    const fresh_z = try allocator.dupeSentinel(u8, "fresh.sock", 0);
    defer allocator.free(fresh_z);

    // A failure after bind (chmod/listen/dup in production) releases only the
    // node this call created.
    try std.testing.expectError(
        error.InjectedBindFailure,
        Listener.bindInternal(allocator, &dir, "fresh.sock", .{}, .after_bind),
    );
    try std.testing.expectError(error.FileNotFound, statAt(dir.fd, fresh_z, true));

    // The same holds with the lock, where a stale entry is removed first.
    var lock = try Lock.acquire(allocator, &dir, "daemon.lock");
    defer lock.release();
    var stale = try Listener.bind(allocator, &dir, "fresh.sock", .{ .lock = &lock });
    stale.close();
    defer stale.deinit();
    try std.testing.expectError(
        error.InjectedBindFailure,
        Listener.bindInternal(allocator, &dir, "fresh.sock", .{ .lock = &lock }, .after_bind),
    );
    try std.testing.expectError(error.FileNotFound, statAt(dir.fd, fresh_z, true));
}

test "bind refuses a renamed or replaced runtime directory" {
    const allocator = std.testing.allocator;
    const me: u32 = @intCast(c.geteuid());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const parent = try testParent(&tmp, &buf);
    const parent_z = try allocator.dupeSentinel(u8, parent, 0);
    defer allocator.free(parent_z);
    const parent_fd = try fs.openDirectory(linux.AT.FDCWD, parent_z);
    defer fs.closeFd(parent_fd);

    var dir = try Directory.resolveUnder(allocator, parent, "rt", me);
    defer dir.deinit();

    var listener = try Listener.bind(allocator, &dir, "live.sock", .{});
    defer listener.deinit();
    const expected = try dir.join(allocator, "live.sock");
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, listener.socketPath());

    const live_z = try allocator.dupeSentinel(u8, "live.sock", 0);
    defer allocator.free(live_z);
    const bound = try statAt(dir.fd, live_z, true);
    try std.testing.expect(Identity.from(bound).eql(listener.socketIdentity()));

    // Move the directory away while its fd is still held: the fd keeps pointing
    // at the same inode, but the published path no longer names it.
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.renameat(parent_fd, "rt", parent_fd, "rt-moved")),
    );
    try std.testing.expectError(error.DirectoryMoved, Listener.bind(allocator, &dir, "other.sock", .{}));

    // A fresh directory at the old path is a different identity: still refused.
    try std.testing.expectEqual(@as(c_int, 0), c.mkdirat(parent_fd, "rt", 0o700));
    try std.testing.expectError(error.DirectoryMoved, Listener.bind(allocator, &dir, "other.sock", .{}));

    // Neither directory received the refused socket.
    try std.testing.expectError(error.FileNotFound, statAt(dir.fd, "other.sock", true));
    const fresh_fd = try fs.openDirectory(parent_fd, "rt");
    defer fs.closeFd(fresh_fd);
    try std.testing.expectError(error.FileNotFound, statAt(fresh_fd, "other.sock", true));
}

test "connect reports a missing endpoint without creating anything" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try testPrivateDir(allocator, &tmp);
    defer dir.deinit();

    const path = try dir.join(allocator, "absent.sock");
    defer allocator.free(path);
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    try std.testing.expectError(error.FileNotFound, connect(allocator, path, @intCast(c.geteuid()), testWait()));
    // The failed client must not leave an entry behind.
    try std.testing.expectError(error.FileNotFound, statAt(linux.AT.FDCWD, path_z, true));
}
