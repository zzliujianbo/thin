//! Native AF_UNIX mechanics. Linux keeps procfs-anchored bind and SO_PEERCRED;
//! Darwin's C-only helper binds, transfers ownership, and NEVER listens.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const linux = std.os.linux;
const fs = @import("filesystem.zig");
const metadata = @import("metadata.zig");

comptime {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos)
        @compileError("AF_UNIX backend supports Linux and macOS only");
}

pub const max_socket_path_len: usize = @sizeOf(@FieldType(c.sockaddr.un, "path")) - 1;
pub const recv_flags: u32 = c.MSG.DONTWAIT;
pub const send_flags: u32 = if (builtin.os.tag == .linux) c.MSG.NOSIGNAL else 0;
pub const step_send_flags: u32 = send_flags | c.MSG.DONTWAIT;
pub const Credentials = struct { pid: u32, uid: u32, gid: u32 };

extern "c" fn thin_darwin_ipc_bind_at(c.fd_t, [*:0]const u8, *u32, *u32, *u64) c_int;
extern "c" fn thin_darwin_ipc_credentials(c.fd_t, *u32, *u32, *u32) c_int;

pub fn errno() c.E {
    return c.errno(@as(c_int, -1));
}

pub fn mapError(e: c.E) anyerror {
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
        .TIMEDOUT => error.Timeout,
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
        .BUSY => error.HelperBusy,
        .OPNOTSUPP => error.OperationNotSupported,
        else => error.UnexpectedSystemError,
    };
}

pub fn osError() anyerror {
    return mapError(errno());
}

/// Darwin has no atomic socket/accept CLOEXEC flags. Every owned fd is made
/// nonblocking/CLOEXEC before exposure; concurrent spawn must use a close-default
/// fd allowlist, not rely solely on a racing fcntl(FD_CLOEXEC).
fn prepare(fd: c.fd_t) !void {
    const status = c.fcntl(fd, c.F.GETFL);
    if (status < 0) return osError();
    const nonblock: u32 = @bitCast(@as(c.O, .{ .NONBLOCK = true }));
    if (c.fcntl(fd, c.F.SETFL, status | @as(c_int, @intCast(nonblock))) < 0) return osError();
    const descriptor = c.fcntl(fd, c.F.GETFD);
    if (descriptor < 0 or c.fcntl(fd, c.F.SETFD, descriptor | @as(c_int, c.FD_CLOEXEC)) < 0) return osError();
    if (builtin.os.tag == .macos) {
        const enabled: c_int = 1;
        // Set while the socket is live, before returning it or sending bytes.
        if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &enabled, @sizeOf(c_int)) != 0) return osError();
    }
}

pub fn socket() !c.fd_t {
    const flags = if (builtin.os.tag == .linux) c.SOCK.STREAM | c.SOCK.CLOEXEC | c.SOCK.NONBLOCK else c.SOCK.STREAM;
    const fd = c.socket(c.AF.UNIX, flags, 0);
    if (fd < 0) return osError();
    errdefer fs.closeFd(fd);
    if (builtin.os.tag == .macos) try prepare(fd);
    return fd;
}

pub fn socketPair() ![2]c.fd_t {
    var fds: [2]c.fd_t = undefined;
    const flags = if (builtin.os.tag == .linux) c.SOCK.STREAM | c.SOCK.CLOEXEC | c.SOCK.NONBLOCK else c.SOCK.STREAM;
    if (c.socketpair(c.AF.UNIX, flags, 0, &fds) != 0) return osError();
    errdefer {
        fs.closeFd(fds[0]);
        fs.closeFd(fds[1]);
    }
    if (builtin.os.tag == .macos) {
        try prepare(fds[0]);
        try prepare(fds[1]);
    }
    return fds;
}

pub fn accept(fd: c.fd_t) !c.fd_t {
    const result = if (builtin.os.tag == .linux)
        c.accept4(fd, null, null, c.SOCK.CLOEXEC | c.SOCK.NONBLOCK)
    else
        c.accept(fd, null, null);
    if (result < 0) return osError();
    errdefer fs.closeFd(result);
    if (builtin.os.tag == .macos) try prepare(result);
    return result;
}

pub fn address(path: []const u8) !c.sockaddr.un {
    if (path.len == 0 or path.len > max_socket_path_len or std.mem.findScalar(u8, path, 0) != null)
        return error.InvalidPath;
    var addr: c.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    if (builtin.os.tag == .macos) addr.len = @intCast(addressLength(path));
    return addr;
}

pub fn addressLength(path: []const u8) c.socklen_t {
    return @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + @as(usize, if (builtin.os.tag == .macos) 1 else 0));
}

pub const Bound = struct { fd: c.fd_t, dev_major: u32, dev_minor: u32, ino: u64 };

/// Returns a bound, UNLISTENED descriptor AND the node identity captured at bind,
/// not a new snapshot of a possibly replaced name. The actual server must call
/// listen after verifying node/directory identity; otherwise Darwin reports helper PID.
pub fn bindAt(a: std.mem.Allocator, dirfd: c.fd_t, name: [*:0]const u8) !Bound {
    const leaf = std.mem.span(name);
    if (leaf.len == 0 or leaf.len > 63 or std.mem.findScalar(u8, leaf, '/') != null or
        std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return error.InvalidName;
    if (builtin.os.tag == .macos) {
        var result: Bound = undefined;
        const fd = thin_darwin_ipc_bind_at(dirfd, name, &result.dev_major, &result.dev_minor, &result.ino);
        if (fd == -2) return error.HelperCleanupUnconfirmed;
        if (fd < 0) return osError();
        result.fd = fd;
        return result;
    }
    const fd = try socket();
    errdefer fs.closeFd(fd);
    const path = try std.fmt.allocPrint(a, "/proc/self/fd/{d}/{s}", .{ dirfd, leaf });
    defer a.free(path);
    var addr = try address(path);
    if (c.bind(fd, @ptrCast(&addr), addressLength(path)) != 0) {
        const e = errno();
        // Never replace descriptor anchoring with a re-resolved absolute path.
        if (e == .NOENT or e == .NOTDIR) return error.FdAnchoredPathUnavailable;
        return mapError(e);
    }
    const st = try metadata.statAt(dirfd, name, true);
    return .{ .fd = fd, .dev_major = st.dev_major, .dev_minor = st.dev_minor, .ino = st.ino };
}

pub fn credentials(fd: c.fd_t) !Credentials {
    if (builtin.os.tag == .macos) {
        var result: Credentials = undefined;
        if (thin_darwin_ipc_credentials(fd, &result.pid, &result.uid, &result.gid) != 0 or result.pid == 0)
            return error.PeerCredentialsUnavailable;
        return result;
    }
    if (builtin.os.tag == .linux) {
        const Ucred = extern struct { pid: c.pid_t, uid: c.uid_t, gid: c.gid_t };
        var value: Ucred = undefined;
        var len: c.socklen_t = @sizeOf(Ucred);
        if (c.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, &value, &len) != 0) return osError();
        if (len != @sizeOf(Ucred) or value.pid <= 0) return error.PeerCredentialsUnavailable;
        return .{ .pid = @intCast(value.pid), .uid = value.uid, .gid = value.gid };
    }
    unreachable;
}
