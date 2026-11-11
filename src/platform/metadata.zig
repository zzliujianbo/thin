//! Security metadata shared by the foreground IPC, registry and worker spawner.
//! No Darwin ABI replicas: std.c selects the INODE64 symbols where required.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const fs = @import("filesystem.zig");

pub const Metadata = struct {
    mode: u16,
    uid: u32,
    gid: u32,
    ino: u64,
    nlink: u64,
    dev_major: u32,
    dev_minor: u32,
    size: u64,
};

fn fromDarwin(st: c.Stat) !Metadata {
    if (st.size < 0) return error.InvalidFileSize;
    const dev: u32 = @bitCast(st.dev);
    return .{
        .mode = st.mode,
        .uid = st.uid,
        .gid = st.gid,
        .ino = st.ino,
        .nlink = st.nlink,
        // Darwin dev_t: unsigned high 8 bits are major, low 24 are minor.
        .dev_major = dev >> 24,
        .dev_minor = dev & 0x00ffffff,
        .size = @intCast(st.size),
    };
}

fn linuxStat(dirfd: c.fd_t, path_z: [*:0]const u8, flags: u32) !Metadata {
    const linux = std.os.linux;
    var st: linux.Statx = undefined;
    if (c.statx(dirfd, path_z, flags, linux.STATX.BASIC_STATS, &st) != 0) return fs.osError();
    // Identity and security checks must not interpret an unavailable field as 0.
    if (!st.mask.TYPE or !st.mask.MODE or !st.mask.UID or !st.mask.GID or
        !st.mask.INO or !st.mask.NLINK or !st.mask.SIZE) return error.MetadataUnavailable;
    return .{
        .mode = st.mode,
        .uid = st.uid,
        .gid = st.gid,
        .ino = st.ino,
        .nlink = st.nlink,
        .dev_major = st.dev_major,
        .dev_minor = st.dev_minor,
        .size = st.size,
    };
}

pub fn statFd(fd: c.fd_t) !Metadata {
    switch (builtin.os.tag) {
        .linux => return linuxStat(fd, "", std.os.linux.AT.EMPTY_PATH),
        .macos => {
            var st: c.Stat = undefined;
            if (c.fstat(fd, &st) != 0) return fs.osError();
            return fromDarwin(st);
        },
        else => @compileError("metadata supports Linux and macOS only"),
    }
}

/// no_follow protects the final component; callers must anchor/walk parents.
pub fn statAt(dirfd: c.fd_t, path_z: [*:0]const u8, no_follow: bool) !Metadata {
    switch (builtin.os.tag) {
        .linux => return linuxStat(dirfd, path_z, if (no_follow) std.os.linux.AT.SYMLINK_NOFOLLOW else 0),
        .macos => {
            var st: c.Stat = undefined;
            if (c.fstatat(dirfd, path_z, &st, if (no_follow) c.AT.SYMLINK_NOFOLLOW else 0) != 0) return fs.osError();
            return fromDarwin(st);
        },
        else => @compileError("metadata supports Linux and macOS only"),
    }
}

/// Rewrite ONLY root-owned Darwin /tmp and /var system aliases. This is not
/// realpath: an arbitrary HOME/project/runtime symlink must still be rejected.
/// The returned path is owned, including when no rewriting was necessary.
pub const systemPath = @import("filesystem_native.zig").systemPath;

/// Walk an absolute directory component-by-component, including ancestors.
/// Known system aliases are handled lexically; no project symlink is followed.
pub fn openDirectoryPath(a: std.mem.Allocator, path: []const u8) !c.fd_t {
    const canonical = try systemPath(a, path);
    defer a.free(canonical);
    var fd = try fs.openDirectory(c.AT.FDCWD, "/");
    errdefer fs.closeFd(fd);
    var parts = std.mem.tokenizeScalar(u8, canonical, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        const z = try a.dupeSentinel(u8, part, 0);
        defer a.free(z);
        const before = try statAt(fd, z, true);
        if (before.mode & c.S.IFMT == c.S.IFLNK) return error.SymlinkNotAllowed;
        if (before.mode & c.S.IFMT != c.S.IFDIR) return error.NotDir;
        const next = try fs.openDirectory(fd, z);
        errdefer fs.closeFd(next);
        const after = try statFd(next);
        if (before.dev_major != after.dev_major or before.dev_minor != after.dev_minor or
            before.ino != after.ino) return error.IdentityChanged;
        fs.closeFd(fd);
        fd = next;
    }
    return fd;
}
