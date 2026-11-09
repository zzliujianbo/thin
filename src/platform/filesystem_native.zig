//! Narrow POSIX filesystem boundary. No leaf open is performed for identityAt:
//! a protected name may be unreadable, a symlink, FIFO, or device. In particular,
//! Darwin O_EVTONLY is NOT Linux O_PATH and can invoke a device's open routine.
const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos)
        @compileError("Filesystem backend supports Linux and macOS only");
}

pub const LOCK = std.c.LOCK;
pub const flock = std.c.flock;

/// Preserve raw syscall return/errno so callers retain their existing policies.
/// A typed O value uses the target libc's flags, not Linux numeric constants.
pub fn openAt(parent: c_int, name: [*:0]const u8, flags: std.c.O, mode: c_uint) c_int {
    return std.c.openat(parent, name, flags, mode);
}

/// Read immediately after a failed libc call, before cleanup can change errno.
pub fn errno() std.c.E {
    return std.c.errno(@as(c_int, -1));
}

pub fn mapError(value: std.c.E) anyerror {
    return switch (value) {
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .EXIST => error.PathAlreadyExists,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .LOOP => error.SymlinkNotAllowed,
        .NAMETOOLONG => error.NameTooLong,
        .NOSPC => error.NoSpaceLeft,
        else => error.FileSystemError,
    };
}

pub fn osError() anyerror {
    return mapError(errno());
}

/// Device encoding is backend-local, never serialized or compared across OSes.
pub const Identity = struct {
    device: u64,
    inode: u64,

    pub fn eql(left: Identity, right: Identity) bool {
        return left.device == right.device and left.inode == right.inode;
    }
};

fn linuxIdentity(parent: c_int, name: [*:0]const u8, flags: u32) !Identity {
    const linux = std.os.linux;
    var result: linux.Statx = undefined;
    if (std.c.statx(parent, name, flags, .{ .INO = true }, &result) != 0) return osError();
    if (!result.mask.INO) return error.FileIdentityUnavailable;
    return .{
        .device = (@as(u64, result.dev_major) << 32) | result.dev_minor,
        .inode = result.ino,
    };
}

fn darwinIdentity(value: std.c.Stat) Identity {
    return .{ .device = @as(u32, @bitCast(value.dev)), .inode = value.ino };
}

/// The caller must keep fd owned/open throughout identity comparisons.
pub fn identity(fd: c_int) !Identity {
    switch (builtin.os.tag) {
        .linux => return linuxIdentity(fd, "", std.os.linux.AT.EMPTY_PATH),
        .macos => {
            var value: std.c.Stat = undefined;
            // std.c selects fstat$INODE64 on Intel Darwin, avoiding a hand-written ABI.
            if (std.c.fstat(fd, &value) != 0) return osError();
            return darwinIdentity(value);
        },
        else => unreachable,
    }
}

/// Snapshot the final entry itself, never follow it and never open it for I/O.
/// The caller supplies an anchored parent and a single validated component.
/// This is not a lease over future namespace changes; do not cache the result.
pub fn identityAt(parent: c_int, name: [*:0]const u8) !Identity {
    switch (builtin.os.tag) {
        .linux => return linuxIdentity(parent, name, std.os.linux.AT.SYMLINK_NOFOLLOW),
        .macos => {
            var value: std.c.Stat = undefined;
            if (std.c.fstatat(parent, name, &value, std.c.AT.SYMLINK_NOFOLLOW) != 0) return osError();
            return darwinIdentity(value);
        },
        else => unreachable,
    }
}

test "filesystem errno mapping uses the target libc constants" {
    const t = std.testing;
    try t.expectEqual(error.SymlinkNotAllowed, mapError(.LOOP));
    try t.expectEqual(error.FileNotFound, mapError(.NOENT));
    try t.expectEqual(error.PathAlreadyExists, mapError(.EXIST));
    try t.expectEqual(error.AccessDenied, mapError(.ACCES));
    try t.expectEqual(error.AccessDenied, mapError(.PERM));
    try t.expectEqual(error.NotDir, mapError(.NOTDIR));
    try t.expectEqual(error.IsDir, mapError(.ISDIR));
    try t.expectEqual(error.NameTooLong, mapError(.NAMETOOLONG));
    try t.expectEqual(error.NoSpaceLeft, mapError(.NOSPC));
    try t.expectEqual(error.FileSystemError, mapError(.IO));
}

test "filesystem identity never equates an inode on different devices" {
    const original: Identity = .{ .device = 1, .inode = 42 };
    try std.testing.expect(original.eql(original));
    try std.testing.expect(!original.eql(.{ .device = 2, .inode = 42 }));
    try std.testing.expect(!original.eql(.{ .device = 1, .inode = 43 }));
}
