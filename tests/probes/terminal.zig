//! 终端（PTY）探针：验证 raw 模式下 termios 的设置与恢复、阻塞输入的取消以及窗口尺寸（winsize）的读写。

const std = @import("std");
// 测试断言工具别名。
const t = std.testing;
const h = @import("common.zig");
const Io = h.Io;
const c = std.c;

// Explicit libc layout; std.c.termios in Zig 0.17 has the smaller kernel ABI.
const abi = @import("terminal_abi");
const openpty = abi.openpty;
const cfmakeraw = abi.cfmakeraw;

/// 一对 PTY 文件描述符：master 为主端，slave 为从端（模拟终端一侧）。
const Pty = struct {
    master: c_int,
    slave: c_int,

    /// 调用 openpty 创建一对 PTY，失败时返回 error.OpenPtyFailed。
    fn open() !Pty {
        var pty: Pty = undefined;
        if (openpty(&pty.master, &pty.slave, null, null, null) != 0)
            return error.OpenPtyFailed;
        return pty;
    }

    /// 关闭主端和从端两个文件描述符。
    fn close(self: Pty) void {
        _ = c.close(self.master);
        _ = c.close(self.slave);
    }
};

/// 读取文件描述符的 termios 属性（tcgetattr）。
fn attributes(fd: c_int) !abi.Termios {
    var result: abi.Termios = undefined;
    if (abi.tcgetattr(fd, &result) != 0) return error.GetAttributesFailed;
    return result;
}

/// 逐字段比较两份 termios 是否相同（输入/输出/控制/本地标志、控制字符与波特率）。
fn sameAttributes(a: abi.Termios, b: abi.Termios) !void {
    try t.expectEqual(a.iflag, b.iflag);
    try t.expectEqual(a.oflag, b.oflag);
    try t.expectEqual(a.cflag, b.cflag);
    try t.expectEqual(a.lflag, b.lflag);
    try t.expectEqualSlices(c.cc_t, &a.cc, &b.cc);
    try t.expectEqual(a.ispeed, b.ispeed);
    try t.expectEqual(a.ospeed, b.ospeed);
}

/// rawScope 的执行模式：normal 正常结束；injected_error 注入错误返回；blocked_read 阻塞在读取上。
const Action = enum { normal, injected_error, blocked_read };
/// 在临时 raw 模式下执行一段作用域。无论成功、出错还是被取消，都会在 defer 中恢复原始 termios。
fn rawScope(io: Io, fd: c_int, action: Action, ready: *h.Flag, restored: *h.Flag) !void {
    // 先保存原始属性，再在副本上切换为 raw 模式，以便恢复。
    var original = try attributes(fd);
    var raw = original;
    cfmakeraw(&raw);
    if (abi.tcsetattr(fd, .NOW, &raw) != 0) return error.SetRawFailed;
    // 恢复属性时记录结果到 restored 标志，供调用者核实。
    defer {
        // Restoration cannot depend on a canceled I/O task accepting more work.
        const result = abi.tcsetattr(fd, .NOW, &original);
        restored.store(result == 0, .release);
    }

    // 确认 raw 模式已生效：关闭规范行编辑（ICANON）与回显（ECHO）。
    const active = try attributes(fd);
    try t.expect(!active.lflag.ICANON and !active.lflag.ECHO);

    ready.store(true, .release);
    switch (action) {
        .normal => {},
        .injected_error => return error.ProbeInjectedFailure,
        .blocked_read => {
            // 直接用 fd 构造 File，并关闭非阻塞模式，使读取真正阻塞等待输入。
            const file = Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
            var byte: [1]u8 = undefined;
            _ = try file.readStreaming(io, &.{byte[0..]});
            return error.UnexpectedTerminalInput;
        },
    }
}

// 验证：raw 模式在正常结束和注入错误时都能恢复原始 termios。
test "probe: PTY raw mode restores on success and injected error" {
    var threaded = h.backend();
    defer threaded.deinit();
    const io = threaded.io();
    const pty = try Pty.open();
    defer pty.close();
    const original = try attributes(pty.slave);
    var ready = h.Flag.init(false);
    var restored = h.Flag.init(false);

    try rawScope(io, pty.slave, .normal, &ready, &restored);
    try t.expect(restored.load(.acquire));
    try sameAttributes(original, try attributes(pty.slave));

    restored.store(false, .release);
    try t.expectError(error.ProbeInjectedFailure, rawScope(io, pty.slave, .injected_error, &ready, &restored));
    try t.expect(restored.load(.acquire));
    try sameAttributes(original, try attributes(pty.slave));
}

// 验证：阻塞中的 PTY 输入能被取消，且在 cancel 返回前已恢复 termios。
test "probe: blocked PTY input cancels and restores termios before completion" {
    var threaded = h.backend();
    defer threaded.deinit();
    const io = threaded.io();
    const pty = try Pty.open();
    defer pty.close();
    const original = try attributes(pty.slave);
    var ready = h.Flag.init(false);
    var restored = h.Flag.init(false);

    var future = try Io.concurrent(io, rawScope, .{ io, pty.slave, Action.blocked_read, &ready, &restored });
    defer future.cancel(io) catch {};
    try h.waitFlag(io, &ready, 2000);
    try Io.sleep(io, .fromMilliseconds(20), .awake);
    try t.expect(!restored.load(.acquire));

    const started = Io.Clock.awake.now(io);
    try t.expectError(error.Canceled, future.cancel(io));
    try t.expect(started.untilNow(io, .awake).toMilliseconds() < 2000);
    try t.expect(restored.load(.acquire));
    try sameAttributes(original, try attributes(pty.slave));
    std.debug.print("PTY_CANCEL elapsed_ms={d}\n", .{started.untilNow(io, .awake).toMilliseconds()});
}

// 验证：可以通过 TIOCSWINSZ 修改并通过 TIOCGWINSZ 读回 PTY 窗口尺寸（列数逐个切换）。
test "probe: PTY window size can be changed and observed" {
    const pty = try Pty.open();
    defer pty.close();

    for ([_]u16{ 40, 80, 120 }) |columns| {
        var requested = std.mem.zeroes(c.winsize);
        requested.row = 24;
        requested.col = columns;
        try t.expectEqual(@as(c_int, 0), c.ioctl(pty.slave, std.os.linux.T.IOCSWINSZ, &requested));

        var actual = std.mem.zeroes(c.winsize);
        try t.expectEqual(@as(c_int, 0), c.ioctl(pty.slave, std.os.linux.T.IOCGWINSZ, &actual));
        try t.expectEqual(columns, actual.col);
        try t.expectEqual(@as(u16, 24), actual.row);
    }
}
