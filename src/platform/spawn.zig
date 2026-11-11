//! Linux: fork 前完成分配；Darwin: posix_spawn + 明确 FD allowlist，无 fork 后 Zig。
//! 返回即转交准确 PID 与三个读端，调用方必须有界清理、最后一次组信号后再 reap。
const std = @import("std");
const c = std.c;
const builtin = @import("builtin");

extern "c" fn thin_darwin_process_spawn(pid: *c.pid_t, executable: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, dir_fd: c.fd_t, input_fd: c.fd_t, output_fd: c.fd_t, error_fd: c.fd_t, inherited_fds: [*]const c.fd_t, inherited_count: usize) c_int;

// Guard owns the first four; Threaded Io owns PIPE/IO. CHLD must also have
// ordinary shell semantics. Prepare all actions/masks before fork.
const reset_signals = [_]c.SIG{ .INT, .TERM, .HUP, .QUIT, .PIPE, .IO, .CHLD };
pub const TestMode = if (@import("builtin").is_test) enum { none, stop_before_exec } else enum { none };

pub const Child = struct {
    pid: c.pid_t,
    stdout: c.fd_t,
    stderr: c.fd_t,
    exec_error: c.fd_t,
    signal_restore_failed: bool,

    pub fn close(self: Child) void {
        _ = c.close(self.stdout);
        _ = c.close(self.stderr);
        _ = c.close(self.exec_error);
    }
};

// 即使父进程关闭了标准 fd，重定向源也不能与 dup2 的目标重叠。
fn aboveStdio(fd: c.fd_t) !c.fd_t {
    if (fd > 2) return fd;
    const moved = c.fcntl(fd, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    _ = c.close(fd);
    if (moved < 0) return error.SpawnFdFailed;
    return moved;
}

fn pipe() ![2]c.fd_t {
    var fds: [2]c.fd_t = undefined;
    if (builtin.os.tag == .linux) {
        if (c.pipe2(&fds, .{ .CLOEXEC = true }) != 0) return error.SpawnPipeFailed;
    } else {
        if (c.pipe(&fds) != 0) return error.SpawnPipeFailed;
        // Not atomic against concurrent spawn. Darwin's CLOEXEC_DEFAULT closes
        // unlisted descriptors even in the pipe/fcntl window.
        for (fds) |fd| {
            if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) {
                _ = c.close(fds[0]);
                _ = c.close(fds[1]);
                return error.SpawnFdFailed;
            }
        }
    }
    fds[0] = aboveStdio(fds[0]) catch |e| {
        _ = c.close(fds[1]);
        return e;
    };
    errdefer _ = c.close(fds[0]);
    fds[1] = try aboveStdio(fds[1]);
    return fds;
}

fn string(a: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidSpawnString;
    return a.dupeSentinel(u8, bytes, 0);
}

// One byte is enough to distinguish startup failure from CLOEXEC EOF. The pipe
// is empty and has one writer; EINTR retries remain subject to the parent's
// timeout/KILL deadline. No child-side allocation or logging is permitted.
fn failed(fd: c.fd_t) noreturn {
    const byte = [1]u8{1};
    while (c.write(fd, &byte, 1) < 0) {
        if (c._errno().* != @backingInt(c.E.INTR)) break;
    }
    c._exit(127);
}

pub fn start(allocator: std.mem.Allocator, root: []const u8, cwd_dir: ?std.Io.Dir, executable: []const u8, script: []const u8, environ: *const std.process.Environ.Map, test_mode: TestMode) !Child {
    return startWithInput(allocator, root, cwd_dir, executable, script, environ, test_mode, null);
}

/// Borrow input without closing or rewinding it in the parent. The duplicate
/// shares its open-file offset; ownership of only the duplicate is transferred.
pub fn startWithInput(allocator: std.mem.Allocator, root: []const u8, cwd_dir: ?std.Io.Dir, executable: []const u8, script: []const u8, environ: *const std.process.Environ.Map, test_mode: TestMode, input: ?std.Io.File) !Child {
    return startWithFds(allocator, root, cwd_dir, executable, script, environ, test_mode, input, &.{});
}

/// Borrow explicit inherited descriptors until return, preserving their exact
/// numbers. Each must be open and > 2; duplicate entries are rejected. Parent
/// flags/ownership are untouched. The caller prevents concurrent close/reuse.
/// Darwin inherits ONLY stdio plus this list; Linux retains its existing exec
/// inheritance policy, clearing CLOEXEC for these descriptors in the child only.
/// Never pass an owner-lifetime pipe's writer to its worker or tool children.
/// A posix_spawn failure returns SpawnFailed with NO transferred child PID.
pub fn startWithFds(allocator: std.mem.Allocator, root: []const u8, cwd_dir: ?std.Io.Dir, executable: []const u8, script: []const u8, environ: *const std.process.Environ.Map, test_mode: TestMode, input: ?std.Io.File, inherited_fds: []const c.fd_t) !Child {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    if (comptime builtin.is_test) {
        if (builtin.os.tag == .macos and test_mode != .none) return error.UnsupportedSpawnTestMode;
    }
    // Validate BEFORE opening internal descriptors: a closed caller FD must not
    // accidentally turn into an internal pipe/cwd descriptor with that number.
    for (inherited_fds, 0..) |fd, index| {
        if (fd <= 2 or c.fcntl(fd, c.F.GETFD) < 0) return error.InvalidInheritedFd;
        if (std.mem.indexOfScalar(c.fd_t, inherited_fds[0..index], fd) != null) return error.InvalidInheritedFd;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exe = try string(a, executable);
    const cwd = try string(a, root);
    const command = try string(a, script);
    const argv = [_:null]?[*:0]const u8{ exe.ptr, "--noprofile", "--norc", "-c", command.ptr };
    const envp = try a.allocSentinel(?[*:0]const u8, environ.count(), null);
    var it = environ.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.indexOfScalar(u8, key, '=') != null) return error.InvalidSpawnString;
        envp[i] = (try string(a, try std.fmt.allocPrint(a, "{s}={s}", .{ key, value }))).ptr;
    }

    const out = try pipe();
    errdefer {
        _ = c.close(out[0]);
        _ = c.close(out[1]);
    }
    const err = try pipe();
    errdefer {
        _ = c.close(err[0]);
        _ = c.close(err[1]);
    }
    const report = try pipe();
    errdefer {
        _ = c.close(report[0]);
        _ = c.close(report[1]);
    }
    // Only the read end is nonblocking; stdout/stderr writers stay blocking.
    const nonblock: u32 = @bitCast(c.O{ .NONBLOCK = true });
    if (c.fcntl(report[0], c.F.SETFL, @as(c_int, @intCast(nonblock))) < 0) return error.SpawnFdFailed;
    const input_fd = if (input) |file| blk: {
        const fd = c.fcntl(file.handle, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (fd < 0) return error.SpawnFdFailed;
        break :blk fd;
    } else blk: {
        const fd = c.open("/dev/null", .{ .CLOEXEC = true });
        if (fd < 0) return error.SpawnFdFailed;
        break :blk try aboveStdio(fd);
    };
    defer _ = c.close(input_fd);
    // Duplicate the anchor before fork, so it too cannot alias fd 0/1/2.
    const dir_fd = if (cwd_dir) |dir| c.fcntl(dir.handle, c.F.DUPFD_CLOEXEC, @as(c_int, 3)) else if (builtin.os.tag == .macos) blk: {
        const fd = c.open(cwd.ptr, .{ .CLOEXEC = true, .DIRECTORY = true });
        if (fd < 0) return error.SpawnFailed;
        break :blk try aboveStdio(fd);
    } else -1;
    if (cwd_dir != null and dir_fd < 0) return error.SpawnFdFailed;
    defer if (dir_fd >= 0) {
        _ = c.close(dir_fd);
    };

    if (builtin.os.tag == .macos) {
        var pid: c.pid_t = undefined;
        if (thin_darwin_process_spawn(&pid, exe.ptr, &argv, envp.ptr, dir_fd, input_fd, out[1], err[1], inherited_fds.ptr, inherited_fds.len) != 0)
            return error.SpawnFailed;
        // Synchronous posix_spawn success proves exec; closing the synthetic
        // report writer preserves Child/status's existing EOF contract. There
        // are NO fallible returns after the PID transfers to this caller.
        _ = c.close(out[1]);
        _ = c.close(err[1]);
        _ = c.close(report[1]);
        return .{ .pid = pid, .stdout = out[0], .stderr = err[0], .exec_error = report[0], .signal_restore_failed = false };
    }

    var defaults = std.mem.zeroes(c.Sigaction);
    defaults.handler = .{ .handler = null };
    var blocked: c.sigset_t = undefined;
    var original: c.sigset_t = undefined;
    if (c.sigemptyset(&defaults.mask) != 0 or c.sigfillset(&blocked) != 0) return error.SpawnSignalFailed;
    // Linux sigprocmask changes only this calling thread's mask. Blocking before
    // fork closes the window in which the child could run a parent handler.
    if (c.sigprocmask(std.os.linux.SIG.BLOCK, &blocked, &original) != 0) return error.SpawnSignalFailed;
    const pid = c.fork();
    if (pid < 0) {
        if (c.sigprocmask(std.os.linux.SIG.SETMASK, &original, null) != 0) return error.SpawnSignalFailed;
        return error.SpawnForkFailed;
    }
    if (pid == 0) {
        // Async-signal-safe libc only. In particular, never unwind into the
        // arena/Io defers inherited from a potentially multithreaded parent.
        if (c.setpgid(0, 0) != 0) failed(report[1]);
        for (reset_signals) |sig| {
            if (c.sigaction(sig, &defaults, null) != 0) failed(report[1]);
        }
        if (c.sigprocmask(std.os.linux.SIG.SETMASK, &defaults.mask, null) != 0) failed(report[1]);
        if (c.dup2(input_fd, 0) < 0 or c.dup2(out[1], 1) < 0 or c.dup2(err[1], 2) < 0) failed(report[1]);
        const changed = if (dir_fd >= 0) c.fchdir(dir_fd) else c.chdir(cwd.ptr);
        if (changed != 0) failed(report[1]);
        _ = c.close(out[0]);
        _ = c.close(out[1]);
        _ = c.close(err[0]);
        _ = c.close(err[1]);
        _ = c.close(report[0]);
        _ = c.close(input_fd);
        // Even a borrowed non-CLOEXEC source must not leak through exec.
        if (input) |file| {
            if (file.handle > 2 and std.mem.indexOfScalar(c.fd_t, inherited_fds, file.handle) == null) _ = c.close(file.handle);
        }
        if (dir_fd >= 0) _ = c.close(dir_fd);
        for (inherited_fds) |fd| {
            const flags = c.fcntl(fd, c.F.GETFD);
            if (flags < 0 or c.fcntl(fd, c.F.SETFD, flags & ~@as(c_int, c.FD_CLOEXEC)) < 0) failed(report[1]);
        }
        // Test-only controlled pre-exec stall; there is no such branch in the
        // product build. The parent must still cancel/timeout and KILL/reap it.
        if (comptime @import("builtin").is_test) {
            if (test_mode == .stop_before_exec) _ = c.raise(.STOP);
        }
        _ = c.execve(exe.ptr, &argv, envp.ptr);
        failed(report[1]);
    }

    // From here there is no fallible return: the caller ALWAYS receives PID.
    // Both sides establish the group, removing the parent's scheduling race.
    _ = c.setpgid(pid, pid);
    _ = c.close(out[1]);
    _ = c.close(err[1]);
    _ = c.close(report[1]);
    const restored = c.sigprocmask(std.os.linux.SIG.SETMASK, &original, null) == 0;
    return .{ .pid = pid, .stdout = out[0], .stderr = err[0], .exec_error = report[0], .signal_restore_failed = !restored };
}

// EOF means the report fd closed, including a child killed before exec. The
// caller must still observe/reap its PID; this status alone never proves exit.
pub const Status = enum { pending, executed, failed };

pub fn status(fd: c.fd_t) !Status {
    var byte: [1]u8 = undefined;
    const n = c.read(fd, &byte, 1);
    if (n > 0) return .failed;
    if (n == 0) return .executed;
    return switch (std.posix.errno(n)) {
        .AGAIN, .INTR => .pending,
        else => error.SpawnReportFailed,
    };
}
