//! POSIX local terminal mechanics (Linux and macOS). Uses a fresh /dev/tty open description, so
//! nonblocking flags do not modify the parent shell's inherited stdio flags.
//! 本地终端：独立打开 /dev/tty、raw 模式恢复、主缓冲显示与非阻塞 I/O。

const std = @import("std");
const c = std.c;
const abi = @import("../platform/terminal_abi.zig");

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

// 测试辅助：逐项比较两份 termios 的标志位、控制字符与波特率。

// 测试：raw 模式与标志仅作用于 PTY，恢复后属性与标志与原始一致。

// Owned-PTY capture of exactly what mode entry writes. The entry bytes are
// read before restoration appends its own leave sequence.

// Startup is exactly the entry control sequence: no CR/LF, no relative cursor
// movement and no erasure. The entry sequence may itself carry SGR/private modes.

// Removing geometric prefill must be proven at every terminal size, including
// the one-row and 200-row clamps of `size()`.

// Shell history stays where the user left it: startup neither moves the seeded
// cursor nor rewrites/erases rows above it (middle, bottom, bottom with a
// pending wrap). The old rows*CRLF+CUU prefill scrolled all of these away.

// 测试：输出缓冲被写满（背压）时仍保持非阻塞，恢复后属性仍然正确。
