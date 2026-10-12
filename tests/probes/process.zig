//! 进程探针：验证子进程的启动与所有权（独立进程组）、管道并发排空、有界输出保留、环境变量过滤，以及 TERM/KILL 清理和取消 wait 的行为。

const std = @import("std");
// 测试断言工具别名。
const t = std.testing;
const h = @import("common.zig");
const Io = h.Io;
// C 库类型别名。
const c = std.c;
// Zig 0.17 has no @cImport. Reuse std.c ABI types for the one missing binding.
/// libc 的 getpgid：返回指定进程所属的进程组 ID，用于验证进程是否自成一组。
extern "c" fn getpgid(pid: c.pid_t) c.pid_t;

/// 构造一个最小化的环境变量表（仅 PATH 和 LANG），避免泄露测试进程的敏感变量。
fn cleanEnvironment() !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(h.alloc);
    errdefer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("LANG", "C");
    return env;
}

/// 以 bash 运行 script，并让它作为新进程组的组长（pgid = 0），从而可以整组发信号。
fn spawnOwned(io: Io, script: []const u8, env: *const std.process.Environ.Map) !std.process.Child {
    const child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/bash", "--noprofile", "--norc", "-c", script },
        .environ_map = env,
        .pgid = 0,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    // 若后续所有权验证失败，则立即 KILL 该进程并清理，避免遗留孤儿进程。
    errdefer {
        _ = c.kill(child.id.?, .KILL);
        _ = reapSaved(child.id.?) catch |err| std.debug.panic("Owned child cleanup failed: {s}", .{@errorName(err)});
        if (child.stdout) |file| file.close(io);
        if (child.stderr) |file| file.close(io);
    }
    const pid = child.id.?;
    // Never signal a negative PID before establishing ownership of this group.
    try t.expect(pid > 1 and getpgid(pid) == pid);
    return child;
}

/// 清理进程组：仅在仍拥有未回收组长时发 KILL；已 reap 的缓存 PGID 绝不可再用。
fn cleanup(io: Io, child: *std.process.Child, group: c.pid_t, owned: *bool) void {
    defer {
        if (child.stdout) |file| file.close(io);
        if (child.stderr) |file| file.close(io);
        child.stdout = null;
        child.stderr = null;
        child.id = null;
    }
    if (!owned.*) return;
    // WNOWAIT confirms retained ownership, never kill(pid, 0). In particular,
    // canceled Child.wait clearing its object is not proof of a successful reap.
    var info: std.os.linux.siginfo_t = std.mem.zeroes(std.os.linux.siginfo_t);
    const rc = std.os.linux.waitid(.PID, group, &info, std.os.linux.W.EXITED | std.os.linux.W.NOHANG | std.os.linux.W.NOWAIT, null);
    if (std.os.linux.errno(rc) != .SUCCESS) {
        if (std.os.linux.errno(rc) == .CHILD) {
            owned.* = false;
            return;
        }
        std.debug.panic("Owned child observation failed", .{});
    }
    // All groups here were created by spawnOwned and verified to be independent.
    const killed = c.kill(-group, .KILL);
    if (killed != 0 and c._errno().* != @backingInt(c.E.SRCH))
        std.debug.panic("Owned process group cleanup failed", .{});
    _ = reapSaved(group) catch |err| switch (err) {
        error.AlreadyReaped => 0,
        else => std.debug.panic("Owned child cleanup failed: {s}", .{@errorName(err)}),
    };
    owned.* = false;
}

/// 用有界 WNOHANG waitpid 回收指定 PID；EINTR 时重试，ECHILD 时返回 AlreadyReaped。
fn reapSaved(pid: c.pid_t) !c_int {
    var status: c_int = undefined;
    const start = Io.Clock.awake.now(t.io);
    while (start.untilNow(t.io, .awake).toMilliseconds() < 2000) {
        const result = c.waitpid(pid, &status, std.os.linux.W.NOHANG);
        if (result == pid) return status;
        if (result < 0) {
            if (c._errno().* == @backingInt(c.E.INTR)) continue;
            if (c._errno().* == @backingInt(c.E.CHILD)) return error.AlreadyReaped;
            return error.ReapFailed;
        }
        var fds: [0]c.pollfd = .{};
        _ = c.poll(&fds, 0, 2);
    }
    return error.ReapTimedOut;
}

/// 输出抓取结果：total 为总字节数，kept 为实际保留的字节数，prefix 为前 4096 字节。
const Output = struct {
    /// 读取到的总字节数（包括未保留的）。
    total: usize = 0,
    /// 已保留到 prefix 中的字节数。
    kept: usize = 0,
    /// 保留的前缀缓冲区，有上限。
    prefix: [4096]u8 = undefined,
};
/// 一直读取管道直到 EOF。只保留前缀，其余字节丢弃但仍计入 total。
fn drain(io: Io, file: Io.File) !Output {
    var result: Output = .{};
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = file.readStreaming(io, &.{buffer[0..]}) catch |err| switch (err) {
            error.EndOfStream => return result,
            else => return err,
        };
        if (count == 0) return result;
        const keep = @min(count, result.prefix.len - result.kept);
        @memcpy(result.prefix[result.kept..][0..keep], buffer[0..keep]);
        result.kept += keep;
        result.total += count;
        // Continue draining after the retention limit, so the child cannot block
        // on a full pipe merely because the model-visible output is bounded.
    }
}

// 验证：stdout/stderr 并发排空，输出保留有界，且敏感环境变量未传入子进程。
test "probe: stdout and stderr drain concurrently with bounded retained output and filtered env" {
    var threaded = h.backend();
    defer threaded.deinit();
    const io = threaded.io();
    try t.expectEqualStrings("fake-probe-secret", try h.env("THIN_PROBE_SECRET"));

    var env = try cleanEnvironment();
    defer env.deinit();

    const script =
        \\test -z "${THIN_PROBE_SECRET+x}" || exit 91
        \\printf 'OUT\n'; printf '%131072s' ''
        \\printf 'ERR\n' >&2; printf '%131072s' '' >&2
        \\exit 7
    ;
    var child = try spawnOwned(io, script, &env);
    const group = child.id.?;
    var owned = true;
    defer cleanup(io, &child, group, &owned);

    var out = try Io.concurrent(io, drain, .{ io, child.stdout.? });
    defer _ = out.cancel(io) catch Output{};
    var err = try Io.concurrent(io, drain, .{ io, child.stderr.? });
    defer _ = err.cancel(io) catch Output{};

    const stdout = try out.await(io);
    const stderr = try err.await(io);
    // Observe without reaping, so the final group signal cannot use a reused ID.
    const started = Io.Clock.awake.now(io);
    while (true) {
        var info: std.os.linux.siginfo_t = std.mem.zeroes(std.os.linux.siginfo_t);
        try t.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.waitid(.PID, group, &info, std.os.linux.W.EXITED | std.os.linux.W.NOHANG | std.os.linux.W.NOWAIT, null)));
        if (info.fields.common.first.piduid.pid == group) break;
        if (started.untilNow(io, .awake).toMilliseconds() >= 2000) return error.ProbeTimedOut;
        var fds: [0]c.pollfd = .{};
        _ = c.poll(&fds, 0, 2);
    }
    try t.expectEqual(@as(c_int, 0), c.kill(-group, .KILL));
    const term = try child.wait(io);
    owned = false;
    try t.expectEqual(std.process.Child.Term{ .exited = 7 }, term);
    try t.expectEqual(@as(usize, 131076), stdout.total);
    try t.expectEqual(@as(usize, 131076), stderr.total);
    try t.expectEqual(@as(usize, 4096), stdout.kept);
    try t.expectEqual(@as(usize, 4096), stderr.kept);

    try t.expectEqualStrings("OUT\n", stdout.prefix[0..4]);
    try t.expectEqualStrings("ERR\n", stderr.prefix[0..4]);
    try t.expect(child.id == null);
}

/// 在后台任务中等待子进程。进入前置位 ready，退出时置位 done。
fn waitChild(io: Io, child: *std.process.Child, ready: *h.Flag, done: *h.Flag, owned: *bool) !std.process.Child.Term {
    ready.store(true, .release);
    defer done.store(true, .release);
    const term = try child.wait(io);
    owned.* = false;
    return term;
}

/// 从管道读取一行（子 shell 打印的 PID）并解析为 pid_t。
fn linePid(io: Io, file: Io.File) !c.pid_t {
    var buffer: [128]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const line = try reader.interface.takeDelimiterExclusive('\n');
    return std.fmt.parseInt(c.pid_t, line, 10);
}

// 验证：TERM 信号能到达自有进程组，子 shell 会回收其后台子进程，且该孙进程在退出后不再存在。
test "probe: TERM reaches an owned process group and the shell reaps its child" {
    var threaded = h.backend();
    defer threaded.deinit();
    const io = threaded.io();
    var env = try cleanEnvironment();
    defer env.deinit();
    const script =
        \\trap 'wait; exit 0' TERM
        \\sleep 10 &
        \\printf '%s\n' "$!"
        \\wait
    ;
    var child = try spawnOwned(io, script, &env);
    const group = child.id.?;
    var owned = true;
    defer cleanup(io, &child, group, &owned);
    const descendant = try linePid(io, child.stdout.?);
    try t.expect(descendant > 1 and getpgid(descendant) == group);

    const started = Io.Clock.awake.now(io);
    // The final signal precedes any potentially reaping waiter.
    try t.expectEqual(@as(c_int, 0), c.kill(-group, .TERM));
    const status = try reapSaved(group);
    owned = false;
    child.id = null;
    const term = Io.Threaded.statusToTerm(@bitCast(status));
    try t.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    try t.expect(child.id == null);

    try t.expectEqual(@as(c_int, -1), c.kill(descendant, @fromBackingInt(@intCast(0))));
    try t.expectEqual(@as(c_int, @backingInt(c.E.SRCH)), c._errno().*);
    std.debug.print("PROCESS_GROUP_TERM elapsed_ms={d}\n", .{started.untilNow(io, .awake).toMilliseconds()});
}

// 验证：取消 wait 不会取代显式的 TERM 再 KILL 清理流程；子进程忽略 TERM，需要手动 KILL 所属组。
// A finite workload avoids an immortal CPU loop if the probe itself is killed.
// This is workload expiry, not guaranteed tree cleanup after arbitrary SIGKILL.
test "probe: canceled wait does not replace explicit TERM then KILL cleanup" {
    var threaded = h.backend();
    defer threaded.deinit();
    const io = threaded.io();
    var env = try cleanEnvironment();
    defer env.deinit();
    const script =
        \\trap '' TERM
        \\printf '%s\n' "$$"
        \\while (( SECONDS < 10 )); do :; done
    ;
    var child = try spawnOwned(io, script, &env);
    const group = child.id.?;
    var owned = true;
    defer cleanup(io, &child, group, &owned);
    try t.expectEqual(group, try linePid(io, child.stdout.?));

    var ready = h.Flag.init(false);
    var done = h.Flag.init(false);
    var waiter = try Io.concurrent(io, waitChild, .{ io, &child, &ready, &done, &owned });
    defer _ = waiter.cancel(io) catch std.process.Child.Term{ .unknown = 0 };
    try h.waitFlag(io, &ready, 2000);

    try t.expectError(error.Canceled, waiter.cancel(io));
    // The object is cleared, but the process is still alive. This must never be
    // interpreted by Runtime as confirmed termination or successful cleanup.
    try t.expect(child.id == null);
    try t.expect(child.stdout == null and child.stderr == null);

    try t.expect(owned);
    try t.expectEqual(@as(c_int, 0), c.kill(-group, .TERM));
    try Io.sleep(io, .fromMilliseconds(30), .awake);
    try t.expect(owned);
    try t.expectEqual(@as(c_int, 0), c.kill(-group, .KILL));

    const status = try reapSaved(group);
    owned = false;
    try t.expect(std.posix.W.IFSIGNALED(@bitCast(status)));
    try t.expectEqual(std.posix.SIG.KILL, std.posix.W.TERMSIG(@bitCast(status)));
    // Deterministically exercise post-reap cleanup: it must not issue signals.
    cleanup(io, &child, group, &owned);
    try t.expect(!owned);
}
