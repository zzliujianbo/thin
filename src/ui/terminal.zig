//! POSIX local terminal mechanics (Linux and macOS). Uses a fresh /dev/tty open description, so
//! nonblocking flags do not modify the parent shell's inherited stdio flags.
//! 本地终端：独立打开 /dev/tty、raw 模式恢复、主缓冲显示与非阻塞 I/O。

const std = @import("std");
const c = std.c;
const abi = @import("../platform/terminal_abi.zig");
const openpty = abi.openpty;
const posix = @import("../platform/posix_terminal.zig");
const remote = @import("../platform/terminal_remote.zig");
// 查询终端的前台进程组，用于判断当前进程是否位于前台。
extern "c" fn tcgetpgrp(c_int) c_int;
// 当前进程所属的进程组，与 tcgetpgrp 的结果比较。
extern "c" fn getpgrp() c_int;
extern "c" fn thin_darwin_terminal_open() c_int;

const nonblock: c_int = @intCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));

/// Supporting terminals present a complete frame together; others ignore this
/// private mode. It supplements owned row diffs, never replaces their safety.
pub const sync_begin = "\x1b[?2026h";
pub const sync_end = "\x1b[?2026l";

// 普通主缓冲：保留 shell 与滚屏内容；只管理自身追加的 live tail。
const enter = "\x1b[?2004h\x1b[0m\x1b[?25l";
// CAN 中止未完成的转义，并释放可能被中断帧开启的同步显示。
// 不切屏、不清屏，最终输出留在滚屏中。
const leave = "\x18\x1b[0m\x1b[?2004l" ++ sync_end ++ "\x1b[?25h\r\n";
/// 终端尺寸，单位为列数与行数。
pub const Size = struct { columns: usize, rows: usize };
/// Cursor row is zero-based; the reported position is untrusted terminal input.
pub const Entry = struct { size: Size, row: usize };

const Cpr = union(enum) { incomplete, invalid, complete: struct { row: usize, length: usize } };

// Only accept a reply at byte zero, never search through user input or paste.
fn parseCpr(bytes: []const u8, size_: Size) Cpr {
    if (bytes.len == 0) return .incomplete;
    if (bytes[0] != 0x1b) return .invalid;
    if (bytes.len == 1) return .incomplete;
    if (bytes[1] != '[') return .invalid;
    var i: usize = 2;
    var row: usize = 0;
    var digits: usize = 0;
    while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {
        // The previous iteration bounded row by the clamped terminal size.
        row = row * 10 + (bytes[i] - '0');
        digits += 1;
        if (row > size_.rows) return .invalid;
    }
    if (i == bytes.len) return .incomplete;
    if (digits == 0 or row == 0 or bytes[i] != ';') return .invalid;
    i += 1;
    var column: usize = 0;
    digits = 0;
    while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {
        column = column * 10 + (bytes[i] - '0');
        digits += 1;
        if (column > size_.columns) return .invalid;
    }
    if (i == bytes.len) return .incomplete;
    if (digits == 0 or column == 0 or bytes[i] != 'R') return .invalid;
    return .{ .complete = .{ .row = row - 1, .length = i + 1 } };
}

/// Optional owner stop check, not used for mandatory terminal restoration.
/// Once bytes are written they cannot be retracted; check before each attempt.
pub const Stop = struct {
    context: ?*const anyopaque = null,
    stopped_fn: *const fn (?*const anyopaque) bool = never,
    fn never(_: ?*const anyopaque) bool {
        return false;
    }
    fn stopped(self: Stop) bool {
        return self.stopped_fn(self.context);
    }
};

/// 终端 fd 的封装：保存原始属性以便恢复，并负责粘贴、光标等显示状态。
pub const Terminal = struct {
    /// 终端文件描述符（/dev/tty 或测试用的 PTY slave）。
    fd: c_int,
    /// 为 true 时 deinit 会关闭 fd：由 open() 打开的 /dev/tty 为 true，外部传入的 fd 为 false。
    owned: bool,
    /// 进入 raw 模式前的 termios 快照，恢复时使用。
    original: abi.Termios,
    /// 进入前的 fcntl 文件状态标志，恢复时用于还原 O_NONBLOCK。
    original_flags: c_int,
    /// 是否仍处于 raw/显示托管状态；restore 依赖它保证幂等。
    active: bool = true,
    restored: bool = false,
    remote: bool = false,
    notification_fd: c_int = -1,
    retained: [64]u8 = @splat(0),
    retained_len: usize = 0,

    /// 打开控制终端 /dev/tty。要求 stdin/stdout 均为 tty，且当前进程位于前台进程组，否则后台写终端会被 SIGTTOU 挂起。
    pub fn open() !Terminal {
        if (remote.active()) {
            var self: Terminal = .{ .fd = -1, .owned = false, .original = undefined, .original_flags = 0, .remote = true };
            errdefer _ = self.restore();
            try self.enterDisplay();
            return self;
        }
        if (c.isatty(0) != 1 or c.isatty(1) != 1) return error.TtyRequired;
        // 使用新的 open 文件描述，使 O_NONBLOCK 不会影响父 shell 继承的 stdio。
        // Darwin poll cannot monitor the indirect /dev/tty device. The C
        // boundary opens its proven controlling node with a fresh description.
        const fd = if (@import("builtin").os.tag == .macos)
            thin_darwin_terminal_open()
        else
            c.openat(c.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true, .NOCTTY = true }, @as(c_uint, 0));
        if (fd < 0) {
            if (@import("builtin").os.tag == .macos and c.errno(fd) == .PERM) return error.ForegroundRequired;
            return error.TtyRequired;
        }
        // 后续任一步失败时关闭刚打开的 fd，避免泄漏。
        errdefer _ = c.close(fd);
        // 不在前台则直接拒绝，避免后台进程修改用户终端状态。
        if (tcgetpgrp(fd) != getpgrp()) return error.ForegroundRequired;
        return fromFd(fd, true);
    }

    /// For owned PTY tests, never applied to the harness/user terminal.
    /// 用给定 fd 建立 Terminal（open() 内部调用，或测试使用 PTY）；会切换到 raw 模式并写入进入序列。
    pub fn fromFd(fd: c_int, owned: bool) !Terminal {
        var original: abi.Termios = undefined;
        if (abi.tcgetattr(fd, &original) != 0) return error.TerminalReadFailed;
        const flags = c.fcntl(fd, c.F.GETFL);
        if (flags < 0) return error.TerminalReadFailed;
        if (c.fcntl(fd, c.F.SETFL, flags | nonblock) < 0) return error.TerminalSetupFailed;
        errdefer _ = c.fcntl(fd, c.F.SETFL, flags);
        // 基于原始属性生成 raw 模式（cfmakeraw 关闭回显、规范模式、信号字符等）。
        var raw = original;
        abi.cfmakeraw(&raw);
        // NOW：立即生效，不等待已排队的输出排空。
        if (abi.tcsetattr(fd, .NOW, &raw) != 0) return error.TerminalSetupFailed;

        // 此时 raw 模式已生效，之后的失败必须经由 errdefer 回滚。
        var self: Terminal = .{ .fd = fd, .owned = owned, .original = original, .original_flags = flags };
        // 进入序列写入失败等错误时，回滚 raw 模式与非阻塞标志。
        errdefer {
            _ = self.restore();
        }
        try self.enterDisplay();
        return self;
    }

    fn enterDisplay(self: *Terminal) !void {
        // Entry handles terminal controls only and does not own geometry.
        // The TUI's real fresh frame performs a bounded native scroll to anchor
        // the tail at the bottom; never clear the screen or replay history here.
        // 进入序列的写入次数有上限（50），避免被背压无限阻塞。
        if (!self.writeBounded(enter, 50)) return error.TerminalSetupFailed;
    }

    /// 查询终端尺寸。ioctl 失败或尺寸为 0 时回退为 80x24；上限为 512x200，防止异常尺寸撑爆缓冲。
    pub fn size(self: Terminal) Size {
        if (self.remote) {
            var columns: c_uint = 80;
            var rows: c_uint = 24;
            remote.size(&columns, &rows);
            return .{ .columns = std.math.clamp(columns, 1, 512), .rows = std.math.clamp(rows, 1, 200) };
        }
        var dimensions = std.mem.zeroes(c.winsize);
        if (posix.getSize(self.fd, &dimensions) != 0) return .{ .columns = 80, .rows = 24 };
        return .{ .columns = if (dimensions.col == 0) 80 else @min(dimensions.col, 512), .rows = if (dimensions.row == 0) 24 else @min(dimensions.row, 200) };
    }

    /// Prove the unclamped physical row count; fallback or unknown sizes are not proof.
    pub fn exactPhysicalRows(self: Terminal, expected: usize) bool {
        if (self.remote) {
            var columns: c_uint = 0;
            var rows: c_uint = 0;
            remote.size(&columns, &rows);
            return rows != 0 and rows == expected;
        }
        var dimensions = std.mem.zeroes(c.winsize);
        return posix.getSize(self.fd, &dimensions) == 0 and
            dimensions.row != 0 and dimensions.row == expected;
    }

    /// Query once before drawing. All non-CPR input remains in order for read().
    /// A timeout, short request, stop or geometry change is a conservative miss.
    pub fn entryPosition(self: *Terminal, io: std.Io, stop: Stop) ?Entry {
        if (!self.active or self.retained_len != 0 or stop.stopped()) return null;
        const dimensions = self.size();
        const start = std.Io.Clock.awake.now(io);
        const request = "\x1b[6n";
        var sent: usize = 0;
        for (0..24) |_| {
            if (stop.stopped() or start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= 45) return null;
            sent += self.write(request[sent..]) catch return null;
            if (sent == request.len) break;
            self.wait(true, 2) catch return null;
        }
        if (sent != request.len) return null;
        for (0..64) |_| {
            if (stop.stopped() or start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= 45) return null;
            const current = self.size();
            if (current.rows != dimensions.rows or current.columns != dimensions.columns) return null;
            const n = self.rawRead(self.retained[self.retained_len..]) catch return null;
            self.retained_len += n;
            switch (parseCpr(self.retained[0..self.retained_len], dimensions)) {
                .invalid => return null,
                .complete => |reply| {
                    const after = self.size();
                    if (stop.stopped() or after.rows != dimensions.rows or after.columns != dimensions.columns) return null;
                    self.discardRetained(reply.length);
                    return .{ .size = dimensions, .row = reply.row };
                },
                .incomplete => {},
            }
            if (self.retained_len == self.retained.len) return null;
            if (n == 0) self.wait(false, 2) catch return null;
        }
        return null;
    }

    fn discardRetained(self: *Terminal, count: usize) void {
        const remaining = self.retained_len - count;
        std.mem.copyForwards(u8, self.retained[0..remaining], self.retained[count..self.retained_len]);
        std.crypto.secureZero(u8, self.retained[remaining..]);
        self.retained_len = remaining;
    }

    /// Reads without waiting; zero means no data currently, not application EOF.
    pub fn read(self: *Terminal, out: []u8) !usize {
        if (self.retained_len != 0) {
            const n = @min(out.len, self.retained_len);
            @memcpy(out[0..n], self.retained[0..n]);
            self.discardRetained(n);
            return n;
        }
        return self.rawRead(out);
    }

    fn rawRead(self: Terminal, out: []u8) !usize {
        if (self.remote) {
            const count = remote.read(out.ptr, out.len);
            return if (count >= 0) @intCast(count) else error.TerminalDisconnected;
        }
        const n = c.read(self.fd, out.ptr, out.len);
        if (n >= 0) return @intCast(n);
        // Temporary lack of data or interruption, not application EOF.
        return switch (c.errno(n)) {
            .INTR, .AGAIN => 0,
            else => error.TerminalDisconnected,
        };
    }

    /// Main loop keeps any unwritten tail and continues input/cancel handling.
    pub fn write(self: Terminal, bytes: []const u8) !usize {
        if (self.remote) {
            const count = remote.write(bytes.ptr, bytes.len);
            return if (count >= 0) @intCast(count) else error.TerminalDisconnected;
        }
        const n = c.write(self.fd, bytes.ptr, bytes.len);
        if (n >= 0) return @intCast(n);
        // The owner retains the unwritten tail on interruption/backpressure.
        return switch (c.errno(n)) {
            .INTR, .AGAIN => 0,
            else => error.TerminalDisconnected,
        };
    }

    /// Register/unregister on the terminal owner thread. The producer must keep
    /// this fd alive until removal; only its queue consumer drains it.
    pub fn setNotification(self: *Terminal, fd: c_int) !void {
        if (self.notification_fd == fd) return;
        if (self.remote and remote.notificationFd(fd) != 0) return error.TerminalSetupFailed;
        self.notification_fd = fd;
    }

    /// 用 poll 等待终端可读（want_write 时等待可写），最多等待 ms 毫秒。
    pub fn wait(self: Terminal, want_write: bool, ms: c_int) !void {
        if (self.remote) {
            if (remote.wait(@intFromBool(want_write), ms) != 0) return error.TerminalDisconnected;
            return;
        }
        var descriptors = [_]c.pollfd{
            .{ .fd = self.fd, .events = c.POLL.IN | (if (want_write) @as(c_short, c.POLL.OUT) else 0), .revents = 0 },
            .{ .fd = self.notification_fd, .events = c.POLL.IN, .revents = 0 },
        };
        const result = c.poll(&descriptors, descriptors.len, ms);
        if (result < 0 and c.errno(result) != .INTR) return error.TerminalDisconnected;
        if (result > 0 and descriptors[0].revents & (c.POLL.ERR | c.POLL.HUP | c.POLL.NVAL) != 0) return error.TerminalDisconnected;
    }

    /// 有界写入：最多尝试 attempts 次，写不完时短暂等待可写。返回是否全部写完，永不无限阻塞。
    fn writeBounded(self: Terminal, data: []const u8, attempts: usize) bool {
        return self.writeBoundedStopped(data, attempts, .{}) catch unreachable;
    }

    fn writeBoundedStopped(self: Terminal, data: []const u8, attempts: usize, stop: Stop) error{Canceled}!bool {
        var offset: usize = 0;
        for (0..attempts) |_| {
            if (stop.stopped()) return error.Canceled;
            offset += self.write(data[offset..]) catch return false;
            if (offset == data.len) return true;
            self.wait(true, 2) catch return false;
        }
        return false;
    }

    /// Restoration must not use a canceled Io context. Bounded even if terminal
    /// output is backpressured; failure is returned, never called success.
    pub fn restore(self: *Terminal) bool {
        std.crypto.secureZero(u8, &self.retained);
        self.retained_len = 0;
        if (!self.active) return self.restored;
        self.active = false;
        if (self.remote) {
            self.restored = self.writeBounded(leave, 50);
            return self.restored;
        }

        var attrs_ok = false;
        // At most eight attempts; only interruption is retryable.
        for (0..8) |_| {
            if (abi.tcsetattr(self.fd, .NOW, &self.original) == 0) {
                attrs_ok = true;
                break;
            }
            if (c.errno(@as(c_int, -1)) != .INTR) break;
        }

        // 即使属性恢复失败，也要尝试输出离开序列（复位样式与粘贴模式）；两项结果分别汇总。
        const display_ok = self.writeBounded(leave, 50);
        // 无论前面是否成功，都尝试还原 O_NONBLOCK 标志。
        const flags_ok = c.fcntl(self.fd, c.F.SETFL, self.original_flags) >= 0;

        // 三项都成功才返回 true，任何失败都如实返回 false。
        self.restored = attrs_ok and display_ok and flags_ok;
        return self.restored;
    }

    /// Plain bounded lifecycle output only AFTER successful restoration. The
    /// fresh tty description remains private; fixture borrowed blocking flags
    /// are temporarily nonblocking and restored even on a short/failed write.
    pub fn writeAfterRestore(self: *Terminal, data: []const u8) !void {
        try self.writeAfterRestoreStopped(data, .{});
    }

    pub fn writeAfterRestoreStopped(self: *Terminal, data: []const u8, stop: Stop) !void {
        if (self.active or !self.restored) return error.TerminalNotRestored;
        if (data.len > 256) return error.TerminalWriteLimit;
        if (self.remote) {
            if (!try self.writeBoundedStopped(data, 50, stop)) return error.TerminalWriteFailed;
            return;
        }
        const flags = c.fcntl(self.fd, c.F.GETFL);
        if (flags < 0 or c.fcntl(self.fd, c.F.SETFL, flags | nonblock) < 0) return error.TerminalWriteFailed;
        // Preserve the error until AFTER temporary flags have been restored.
        const complete = self.writeBoundedStopped(data, 50, stop);
        const flags_ok = c.fcntl(self.fd, c.F.SETFL, flags) >= 0;
        if (!flags_ok) return error.TerminalRestoreFailed;
        if (!try complete) return error.TerminalWriteFailed;
    }

    /// 恢复终端状态；owned 为 true 时同时关闭 fd。可重复调用。
    pub fn deinit(self: *Terminal) void {
        self.setNotification(-1) catch {};
        _ = self.restore();
        if (self.owned) {
            _ = c.close(self.fd);
            self.owned = false;
        }
    }
};

test "local terminal wait observes borrowed wakeup without consuming it as input" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    var wake = try @import("../platform/wakeup.zig").Wakeup.init();
    defer wake.deinit();
    try terminal.setNotification(wake.fd);
    defer terminal.setNotification(-1) catch {};
    wake.notify();
    const start = std.Io.Clock.awake.now(std.testing.io);
    try terminal.wait(false, 500);
    try std.testing.expect(start.untilNow(std.testing.io, .awake).toMilliseconds() < 250);
    var input: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try terminal.read(&input));
    var descriptor = [_]c.pollfd{.{ .fd = wake.fd, .events = c.POLL.IN }};
    try std.testing.expectEqual(@as(c_int, 1), c.poll(&descriptor, 1, 0));
    wake.drain();
    try std.testing.expectEqual(@as(c_int, 0), c.poll(&descriptor, 1, 0));
    try terminal.setNotification(-1);
    terminal.deinit();
    try std.testing.expect(c.fcntl(wake.fd, c.F.GETFD) >= 0);
}

test "CPR parser accepts only an in-range complete first reply" {
    const dimensions = Size{ .columns = 80, .rows = 24 };
    const reply = "\x1b[12;34R";
    for (0..reply.len) |i| try std.testing.expect(parseCpr(reply[0..i], dimensions) == .incomplete);
    const parsed = parseCpr(reply ++ "keys", dimensions);
    try std.testing.expect(parsed == .complete);
    try std.testing.expectEqual(@as(usize, 11), parsed.complete.row);
    try std.testing.expectEqual(reply.len, parsed.complete.length);
    for ([_][]const u8{ "x\x1b[1;1R", "\x04", "\x1b[200~paste\x1b[1;1R", "\x1b[0;1R", "\x1b[25;1R", "\x1b[1;81R", "\x1b[1;0R", "\x1b[;1R", "\x1b[1;xR" }) |bad|
        try std.testing.expect(parseCpr(bad, dimensions) == .invalid);
}

test "entry probe preserves raw suffix and non replies and wipes consumed input" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var dimensions = std.mem.zeroes(c.winsize);
    dimensions.col = 80;
    dimensions.row = 24;
    try std.testing.expectEqual(@as(c_int, 0), posix.setSize(slave, &dimensions));
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    const input = "\x1b[12;34Rabc";
    try std.testing.expectEqual(@as(isize, input.len), c.write(master, input.ptr, input.len));
    const entry = terminal.entryPosition(std.testing.io, .{}) orelse return error.MissingEntry;
    try std.testing.expectEqual(@as(usize, 11), entry.row);
    var result: [32]u8 = undefined;
    const n = try terminal.read(&result);
    try std.testing.expectEqualStrings("abc", result[0..n]);
    try std.testing.expectEqualSlices(u8, &@as([64]u8, @splat(0)), &terminal.retained);
    const paste = "\x1b[200~hello";
    try std.testing.expectEqual(@as(isize, paste.len), c.write(master, paste.ptr, paste.len));
    try std.testing.expect(terminal.entryPosition(std.testing.io, .{}) == null);
    const p = try terminal.read(&result);
    try std.testing.expectEqualStrings(paste, result[0..p]);
    terminal.retained[0] = 42;
    terminal.retained_len = 1;
    _ = terminal.restore();
    try std.testing.expectEqualSlices(u8, &@as([64]u8, @splat(0)), &terminal.retained);
}

test "entry probe timeout and stop are bounded" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    const start = std.Io.Clock.awake.now(std.testing.io);
    try std.testing.expect(terminal.entryPosition(std.testing.io, .{}) == null);
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(std.testing.io)).toMilliseconds() < 500);
    const Always = struct {
        fn stopped(_: ?*const anyopaque) bool {
            return true;
        }
    };
    try std.testing.expect(terminal.entryPosition(std.testing.io, .{ .stopped_fn = Always.stopped }) == null);
}

/// 测试辅助：逐项比较两份 termios 的标志位、控制字符与波特率。
fn expectAttributes(a: abi.Termios, b: abi.Termios) !void {
    try std.testing.expectEqual(a.iflag, b.iflag);
    try std.testing.expectEqual(a.oflag, b.oflag);
    try std.testing.expectEqual(a.cflag, b.cflag);
    try std.testing.expectEqual(abi.configuredLocalFlags(a.lflag), abi.configuredLocalFlags(b.lflag));
    try std.testing.expectEqualSlices(c.cc_t, &a.cc, &b.cc);
    try std.testing.expectEqual(a.ispeed, b.ispeed);
    try std.testing.expectEqual(a.ospeed, b.ospeed);
}

test "physical rows require an exact raw PTY size" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var size = std.mem.zeroes(c.winsize);
    size.col = 80;
    size.row = 24;
    try std.testing.expectEqual(@as(c_int, 0), posix.setSize(slave, &size));
    const terminal: Terminal = .{ .fd = slave, .owned = false, .original = undefined, .original_flags = 0, .active = false };
    try std.testing.expect(terminal.exactPhysicalRows(24));
    try std.testing.expect(!terminal.exactPhysicalRows(200));
    size.row = 500;
    try std.testing.expectEqual(@as(c_int, 0), posix.setSize(slave, &size));
    try std.testing.expect(!terminal.exactPhysicalRows(200));
    var invalid = terminal;
    invalid.fd = -1;
    try std.testing.expect(!invalid.exactPhysicalRows(24));
}

// 测试：raw 模式与标志仅作用于 PTY，恢复后属性与标志与原始一致。
test "product terminal restores raw attributes and flags on PTY only" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var original: abi.Termios = undefined;
    try std.testing.expectEqual(@as(c_int, 0), abi.tcgetattr(slave, &original));
    const flags = c.fcntl(slave, c.F.GETFL);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    var raw: abi.Termios = undefined;
    try std.testing.expectEqual(@as(c_int, 0), abi.tcgetattr(slave, &raw));
    try std.testing.expect(!raw.lflag.ICANON and !raw.lflag.ECHO);
    for ([_]u16{ 40, 80, 120 }) |columns| {
        var size = std.mem.zeroes(c.winsize);
        size.col = columns;
        size.row = 24;
        try std.testing.expectEqual(@as(c_int, 0), posix.setSize(slave, &size));
        try std.testing.expectEqual(@as(usize, columns), terminal.size().columns);
    }

    try std.testing.expectError(error.TerminalNotRestored, terminal.writeAfterRestore("premature"));
    try std.testing.expect(terminal.restore());
    try terminal.writeAfterRestore("Session ID: 00000000000000000000000000000000\r\n");
    try std.testing.expect(terminal.restore());
    var restored: abi.Termios = undefined;
    try std.testing.expectEqual(@as(c_int, 0), abi.tcgetattr(slave, &restored));
    try expectAttributes(original, restored);
    try std.testing.expectEqual(posix.configuredFileFlags(flags), posix.configuredFileFlags(c.fcntl(slave, c.F.GETFL)));
}

test "restoration releases synchronized display after interrupted frame escapes on owned PTY" {
    const end = "\x1b[?2026l";
    for ([_][]const u8{ "\x1b[?2026h", "\x1b[?2026hpartial-frame\x1b[?2026", "\x1b[?202" }) |partial| {
        var master: c_int = undefined;
        var slave: c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
        defer _ = c.close(master);
        defer _ = c.close(slave);
        try std.testing.expect(c.fcntl(master, c.F.SETFL, c.fcntl(master, c.F.GETFL) | nonblock) >= 0);
        var terminal = try Terminal.fromFd(slave, false);
        defer terminal.deinit();
        try std.testing.expect(terminal.writeBounded(partial, 10));
        try std.testing.expect(terminal.restore());
        var buffer: [2048]u8 = undefined;
        var used: usize = 0;
        for (0..20) |_| {
            var pollfd = [_]c.pollfd{.{ .fd = master, .events = c.POLL.IN, .revents = 0 }};
            if (c.poll(&pollfd, 1, 10) <= 0) continue;
            const n = c.read(master, buffer[used..].ptr, buffer.len - used);
            if (n > 0) used += @intCast(n);
            if (std.mem.find(u8, buffer[0..used], "\x1b[?25h") != null or used == buffer.len) break;
        }
        const release = std.mem.find(u8, buffer[0..used], end) orelse return error.MissingSyncRelease;
        const show = std.mem.find(u8, buffer[0..used], "\x1b[?25h") orelse return error.MissingCursorRestore;
        try std.testing.expect(release + end.len <= show);
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try screen.replay(buffer[0..used]); // CAN also cancels a partial begin/end.
        var restored: abi.Termios = undefined;
        try std.testing.expectEqual(@as(c_int, 0), abi.tcgetattr(slave, &restored));
        try expectAttributes(terminal.original, restored);
        try std.testing.expectEqual(posix.configuredFileFlags(terminal.original_flags), posix.configuredFileFlags(c.fcntl(slave, c.F.GETFL)));
    }
}

test "post restoration stop on a backpressured retry still restores descriptor flags" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    try std.testing.expect(terminal.restore());
    const flags = c.fcntl(slave, c.F.GETFL);
    try std.testing.expect(flags >= 0);
    // Darwin may still admit writes while output is paused. Fill even the last
    // byte of queue space so a small report cannot race a large-write EAGAIN.
    try std.testing.expectEqual(@as(c_int, 0), posix.pauseOutput(slave, true));
    defer _ = posix.pauseOutput(slave, false);
    try std.testing.expect(c.fcntl(slave, c.F.SETFL, flags | nonblock) >= 0);
    defer _ = c.fcntl(slave, c.F.SETFL, flags);
    var blocked = false;
    for (0..1024 * 1024) |_| {
        const n = c.write(slave, "x", 1);
        if (n == 1) continue;
        if (n < 0 and c.errno(n) == .INTR) continue;
        try std.testing.expectEqual(c.E.AGAIN, c.errno(n));
        blocked = true;
        break;
    }
    try std.testing.expect(blocked);
    try std.testing.expect(c.fcntl(slave, c.F.SETFL, flags) >= 0);
    const Reader = struct {
        fn stopped(ctx: ?*const anyopaque) bool {
            const immutable: *const usize = @ptrCast(@alignCast(ctx.?));
            const count = @constCast(immutable);
            count.* += 1;
            return count.* >= 2;
        }
    };
    var calls: usize = 0;
    try std.testing.expectError(error.Canceled, terminal.writeAfterRestoreStopped("bounded-report", .{ .context = &calls, .stopped_fn = Reader.stopped }));
    try std.testing.expectEqual(@as(usize, 2), calls);
    try std.testing.expectEqual(posix.configuredFileFlags(flags), posix.configuredFileFlags(c.fcntl(slave, c.F.GETFL)));
    try std.testing.expect(terminal.restore());
}

test "failed restoration never becomes success or allows exit identity output" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    defer _ = c.close(master);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    try std.testing.expectEqual(@as(c_int, 0), c.close(slave));
    try std.testing.expect(!terminal.restore());
    try std.testing.expect(!terminal.restore());
    try std.testing.expectError(error.TerminalNotRestored, terminal.writeAfterRestore("must not print"));
}

/// Owned-PTY capture of exactly what mode entry writes. The entry bytes are
/// read before restoration appends its own leave sequence.
fn captureStartup(output: []u8, columns: u16, screen_rows: u16) ![]const u8 {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var dimensions = std.mem.zeroes(c.winsize);
    dimensions.col = columns;
    dimensions.row = screen_rows;
    try std.testing.expectEqual(@as(c_int, 0), posix.setSize(slave, &dimensions));
    try std.testing.expect(c.fcntl(master, c.F.SETFL, c.fcntl(master, c.F.GETFL) | nonblock) >= 0);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    return try drainMaster(master, output);
}

fn drainMaster(master: c_int, output: []u8) ![]const u8 {
    var used: usize = 0;
    while (used < output.len) {
        const n = c.read(master, output[used..].ptr, output.len - used);
        if (n > 0) {
            used += @intCast(n);
            continue;
        }
        // Empty nonblocking queue is EAGAIN; anything else is a real PTY fault.
        if (n < 0) try std.testing.expectEqual(c.E.AGAIN, c.errno(n));
        var descriptor = [_]c.pollfd{.{ .fd = master, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&descriptor, 1, 20) <= 0) break;
    }
    return output[0..used];
}

/// Startup is exactly the entry control sequence: no CR/LF, no relative cursor
/// movement and no erasure. The entry sequence may itself carry SGR/private modes.
fn expectEntryOnly(bytes: []const u8) !void {
    try std.testing.expectEqualStrings(enter, bytes);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '\r') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, '\n') == null);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, "\x1b[")) |at| {
        i = at + 2;
        while (i < bytes.len and !(bytes[i] >= 0x40 and bytes[i] <= 0x7e)) i += 1;
        if (i == bytes.len) return error.IncompleteEscape;
        switch (bytes[i]) {
            'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'J', 'K', 'L', 'M', 'P', 'S', 'T', 'f' => return error.CursorGeometrySequence,
            else => i += 1,
        }
    }
}

// Removing geometric prefill must be proven at every terminal size, including
// the one-row and 200-row clamps of `size()`.
test "mode entry emits only the bounded enter sequence on owned PTYs" {
    var captured: [64]u8 = undefined;
    for ([_]u16{ 1, 2, 24, 200 }) |rows| {
        const startup = try captureStartup(&captured, 80, rows);
        try expectEntryOnly(startup);
    }
}

// Shell history stays where the user left it: startup neither moves the seeded
// cursor nor rewrites/erases rows above it (middle, bottom, bottom with a
// pending wrap). The old rows*CRLF+CUU prefill scrolled all of these away.
test "mode entry preserves seeded cursor and prior rows at middle and bottom" {
    const regular = @import("../tests/regular_screen.zig");
    var captured: [64]u8 = undefined;
    const startup = try captureStartup(&captured, 80, 24);
    try expectEntryOnly(startup);
    const Seed = struct { row: usize, col: usize, wrap: bool };
    for ([_]Seed{
        .{ .row = 11, .col = 0, .wrap = false },
        .{ .row = 12, .col = 7, .wrap = false },
        .{ .row = 23, .col = 79, .wrap = true },
    }) |seed| {
        var screen: regular.Screen = .{};
        try screen.replay(regular.prior ++ "\r\nfirst-row\r\nsecond-row\r\nthird-row");
        screen.row = seed.row;
        screen.col = seed.col;
        screen.wrap = seed.wrap;
        const history = screen.history_len;
        const grid = screen.grid;
        try screen.replay(startup);
        try std.testing.expectEqual(seed.row, screen.row);
        try std.testing.expectEqual(seed.col, screen.col);
        try std.testing.expectEqual(seed.wrap, screen.wrap);
        try std.testing.expectEqual(history, screen.history_len);
        for (0..grid.len) |row_index|
            try std.testing.expectEqualSlices(u8, &grid[row_index], &screen.grid[row_index]);
        try std.testing.expectEqual(@as(usize, 1), screen.count(regular.prior));
        for ([_][]const u8{ "first-row", "second-row", "third-row" }) |row|
            try std.testing.expectEqual(@as(usize, 1), screen.count(row));
    }
}

// 测试：输出缓冲被写满（背压）时仍保持非阻塞，恢复后属性仍然正确。
test "backpressured terminal stays nonblocking and reports failed display restoration" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    // Close the master first so macOS does not wait for unread output on the
    // slave's close. The terminal restores its leave sequence before this runs.
    defer _ = c.close(slave);
    defer _ = c.close(master);
    var terminal = try Terminal.fromFd(slave, false);
    defer terminal.deinit();
    const bytes: [4096]u8 = @splat('x');
    var total: usize = 0;
    // 持续写入直到内核缓冲区写满（write 返回 0），证明写操作不会阻塞。
    while (total < 1024 * 1024) {
        const n = try terminal.write(&bytes);
        if (n == 0) break;
        total += n;
    }
    try std.testing.expect(total < 1024 * 1024);

    _ = terminal.restore(); // Kernel may make a little extra output space; either is honest.
    var restored: abi.Termios = undefined;
    try std.testing.expectEqual(@as(c_int, 0), abi.tcgetattr(slave, &restored));
    try expectAttributes(terminal.original, restored);
}
