//! Linux x86_64 application PTY acceptance. Never opens the user's terminal.
//! 中文：Linux x86_64 应用级 PTY 验收驱动。它只使用 openpty 创建的伪终端，不会打开用户自己的终端。

const std = @import("std");
const c = std.c;
const abi = @import("../platform/terminal_abi.zig");
const openpty = abi.openpty;
const regular = @import("regular_screen.zig");
const spinner_theme = @import("../ui/theme.zig");

// libc 符号声明：fork/exec、信号、进程组与 PTY 控制相关函数。
extern "c" fn fork() c_int;
extern "c" fn signal(c_int, *const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;

/// 由信号处理器置位的中断标志；acquire/release 保证驱动循环能及时看到它。
var interrupted: std.atomic.Value(bool) = .init(false);

/// 信号处理器：只写原子标志，保持 async-signal-safe。
fn onSignal(_: c_int) callconv(.c) void {
    interrupted.store(true, .release);
}

extern "c" fn setsid() c_int;
extern "c" fn chdir([*:0]const u8) c_int;
extern "c" fn dup2(c_int, c_int) c_int;
extern "c" fn execve([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(c_int) noreturn;
extern "c" fn waitpid(c_int, *c_int, c_int) c_int;
extern "c" fn kill(c_int, c_int) c_int;
extern "c" fn getpgid(c_int) c_int;

/// 与 libc struct timespec 布局一致（x86_64 下为两个 64 位整数）。
const Timespec = extern struct { sec: i64, ns: i64 };
extern "c" fn clock_gettime(c_int, *Timespec) c_int;

/// 返回单调时钟的毫秒数；时钟读取失败时返回 0。
fn now() i64 {
    var t: Timespec = undefined;
    // 1 == CLOCK_MONOTONIC，超时计算不受系统时间调整影响。
    if (clock_gettime(1, &t) != 0) return 0;
    return t.sec * 1000 + @divTrunc(t.ns, 1000000);
}

/// 断言辅助：条件不成立时返回 AcceptanceFailed。
fn check(ok: bool) !void {
    if (!ok) return error.AcceptanceFailed;
}

/// PTY 驱动器：持有 master/slave 与子进程 PID，负责读写终端、收集输出，并校验退出状态与终端恢复情况。
const Driver = struct {
    /// 主端 fd：驱动方通过它向应用发送按键、读取屏幕输出。
    master: c_int,
    /// 从端 fd：作为子进程的 stdin/stdout/stderr；用于结束时检查 termios 是否恢复。
    slave: c_int,
    /// 子进程 PID。
    pid: c_int,
    /// 子进程是否仍归本驱动器所有（未被回收）。回收后置为 false，之后不再发信号，避免 PID 被复用后误杀。
    owned: bool = true,
    /// waitpid 返回的原始状态字（正常退出时 exit code 位于高 8 位）。
    status: c_int = 0,
    /// 启动前 slave 的 termios，结束时用于比对是否完整恢复。
    original: abi.Termios,
    /// 启动前 slave 的 fcntl 标志，结束时用于比对。
    flags: c_int,
    /// 输出缓冲区，固定 2 MiB 上限；超出时返回 OutputLimit。
    output: [2 * 1024 * 1024]u8 = undefined,
    /// output 中已写入的字节数。
    used: usize = 0,

    /// 在最多 ms 毫秒内轮询 master 并读尽可读数据；若子进程仍归属本驱动器，则非阻塞检查它是否已退出。
    fn drain(self: *Driver, ms: c_int) !void {
        if (interrupted.load(.acquire)) return error.DriverInterrupted;
        var poll = [_]c.pollfd{.{ .fd = self.master, .events = 1, .revents = 0 }};
        _ = c.poll(&poll, 1, ms);
        while (true) {
            var buf: [8192]u8 = undefined;
            const n = c.read(self.master, &buf, buf.len);
            if (n <= 0) break;
            const count: usize = @intCast(n);
            if (self.used + count > self.output.len) return error.OutputLimit;
            @memcpy(self.output[self.used..][0..count], buf[0..count]);
            self.used += count;
        }

        if (self.owned) {
            // WNOHANG (1)：非阻塞回收，避免 drain 被子进程挂住。
            const result = waitpid(self.pid, &self.status, 1);
            if (result == self.pid) {
                self.owned = false;
            } else if (result < 0 and c._errno().* != 4) {
                // EINTR (4) 视为可忽略并重试；其他错误中 ECHILD (10) 表示已不可回收。
                if (c._errno().* == 10) self.owned = false; // ECHILD: never signal a possibly reused PID.
                return error.WaitFailed;
            }
        }
    }

    /// 等待 output 中自 start 偏移之后出现 needle，最长 10 秒；期间子进程提前退出则失败。
    fn waitText(self: *Driver, start: usize, needle: []const u8) !void {
        const until = now() + 10000;
        while (now() < until) {
            try self.drain(20);
            if (std.mem.indexOf(u8, self.output[start..self.used], needle) != null) return;
            if (!self.owned) return error.EarlyExit;
        }
        return error.VisibleTextTimeout;
    }

    /// A visible menu fragment is not an acknowledged complete owned frame.
    fn waitFrame(self: *Driver, start: usize, needle: []const u8) !void {
        const until = now() + 10000;
        while (now() < until) {
            try self.drain(20);
            const bytes = self.output[start..self.used];
            if (std.mem.indexOf(u8, bytes, needle)) |at| {
                if (std.mem.indexOf(u8, bytes[at + needle.len ..], "\x1b[?25h") != null) return;
            }
            if (!self.owned) return error.EarlyExit;
        }
        return error.VisibleTextTimeout;
    }

    /// A generated/ready caption is already visible before execution. Observe
    /// the current complete screen's braille row, not an earlier name match.
    fn waitRunningFrame(self: *Driver, start: usize, command: []const u8) !void {
        const view = try std.heap.page_allocator.create(regular.Screen);
        defer std.heap.page_allocator.destroy(view);
        var buffer: [512]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buffer, "~ {s}", .{command});
        const until = now() + 10000;
        while (now() < until) {
            try self.drain(20);
            const raw = self.output[0..self.used];
            const ack = std.mem.lastIndexOf(u8, raw, "\x1b[?25h") orelse continue;
            if (ack < start) continue;
            view.* = .{};
            try view.replay(raw[0 .. ack + "\x1b[?25h".len]);
            if (view.visible(needle)) return;
            if (!self.owned) return error.EarlyExit;
        }
        return error.RunningToolFrameTimeout;
    }

    /// Completion has no label. Match the idle prefix's percentage tail only
    /// in new output: colored text resets before the neutral parentheses and
    /// marker; unselected startup has a bare prompt. Keep the full-frame cursor ACK.
    fn waitIdle(self: *Driver, start: usize) !void {
        const until = now() + 10000;
        while (now() < until) {
            try self.drain(20);
            const bytes = self.output[start..self.used];
            for ([_][]const u8{
                "%) > ",
                "%\x1b[0m) > ",
            }) |idle| if (std.mem.indexOf(u8, bytes, idle)) |marker| {
                if (std.mem.indexOf(u8, bytes[marker + idle.len ..], "\x1b[?25h") != null) return;
            };
            if (std.mem.indexOf(u8, bytes, "\x1b[0m> \x1b[0m\x1b[K")) |marker| {
                if (std.mem.indexOf(u8, bytes[marker..], "\x1b[?25h") != null) {
                    const visible = try self.screen();
                    if (std.mem.startsWith(u8, &visible.grid[visible.row], "> ")) return;
                }
            }
            if (!self.owned) return error.EarlyExit;
        }
        return error.VisibleTextTimeout;
    }

    /// Busy evidence requires a percentage prefix, a renderer-owned braille
    /// marker and the subsequent completed-frame cursor acknowledgement.
    fn waitBusy(self: *Driver, start: usize) !void {
        const until = now() + 10000;
        while (now() < until) {
            try self.drain(20);
            const bytes = self.output[start..self.used];
            var from: usize = 0;
            const busy_prefix = "%\x1b[0m) "; // Static occupancy color resets before closing parenthesis.
            while (std.mem.indexOfPos(u8, bytes, from, busy_prefix)) |prefix| {
                from = prefix + busy_prefix.len;
                // Accept only the running-tool palette, with a reset before
                // the editor's space. Neither TPS nor effort colors qualify.
                for (spinner_theme.command_pulse) |tone| {
                    if (!std.mem.startsWith(u8, bytes[from..], tone)) continue;
                    const marker = from + tone.len;
                    for ([_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }) |icon| {
                        if (std.mem.startsWith(u8, bytes[marker..], icon) and
                            std.mem.startsWith(u8, bytes[marker + icon.len ..], spinner_theme.reset ++ " ") and
                            std.mem.indexOf(u8, bytes[marker + icon.len ..], "\x1b[?25h") != null) return;
                    }
                }
            }
            if (!self.owned) return error.EarlyExit;
        }
        return error.VisibleTextTimeout;
    }

    /// One actual blank retained row between the sent message and live content.
    fn checkGap(screen_value: *const regular.Screen, before: []const u8, after: []const u8) !void {
        var first: ?usize = null;
        var second: ?usize = null;
        for (0..screen_value.history_len + screen_value.grid.len) |i| {
            const line = if (i < screen_value.history_len) &screen_value.history[i] else &screen_value.grid[i - screen_value.history_len];
            if (first == null and std.mem.indexOf(u8, line, before) != null) first = i;
            if (second == null and std.mem.indexOf(u8, line, after) != null) second = i;
        }
        try check(first != null and second != null);
        try check(second.? == first.? + 2);
        const gap = first.? + 1;
        const line = if (gap < screen_value.history_len) &screen_value.history[gap] else &screen_value.grid[gap - screen_value.history_len];
        for (line) |byte| try check(byte == ' ');
    }

    /// Fixed-size replay only: resize cases check sequences, not terminal reflow.
    fn screen(self: *const Driver) !regular.Screen {
        var result: regular.Screen = .{};
        try result.replay(self.output[0..self.used]);
        return result;
    }

    /// Candidate rows stay below prior output and directly above the composer.
    fn checkMenu(self: *const Driver, candidate: []const u8, composer: []const u8) !void {
        const view = try self.screen();
        try check(view.count(regular.prior) == 1);
        try check(!view.visible("Commands") and !view.visible("Configure provider (API key)"));
        var prior_row: ?usize = null;
        var candidate_row: ?usize = null;
        var composer_row: ?usize = null;
        for (0..view.history_len + view.grid.len) |i| {
            const line = if (i < view.history_len) &view.history[i] else &view.grid[i - view.history_len];
            if (std.mem.indexOf(u8, line, regular.prior) != null) prior_row = i;
            if (std.mem.indexOf(u8, line, candidate) != null) candidate_row = i;
            if (std.mem.indexOf(u8, line, composer) != null) composer_row = i;
        }
        try check(prior_row != null and candidate_row != null and composer_row != null);
        try check(prior_row.? < candidate_row.? and candidate_row.? < composer_row.?);
        try check(composer_row.? - candidate_row.? <= 11); // Ten candidates plus the blank composer separator.
    }

    /// The selected provider (or local fixture endpoint) must be visible before
    /// Enter opens masked input. Mode changes intentionally drop batched bytes.
    fn openAuth(self: *Driver) !void {
        var start = self.used;
        try self.send("/login\r");
        try self.waitFrame(start, "Provider> ");
        start = self.used;
        try self.send("\r");
        try self.waitFrame(start, "API key>");
    }

    /// 向 master 写入 bytes，最长 2 秒；写缓冲满（写入返回 0）时先 drain，避免与应用互相阻塞。
    fn send(self: *Driver, bytes: []const u8) !void {
        var pos: usize = 0;
        const until = now() + 2000;
        while (pos < bytes.len and now() < until) {
            const n = c.write(self.master, bytes[pos..].ptr, bytes.len - pos);
            if (n > 0) pos += @intCast(n) else try self.drain(10);
        }
        try check(pos == bytes.len);
    }

    /// 持续 drain 指定毫秒，用于等待界面稳定（确保拿到完整帧，而不是只有帧头前缀）。
    fn quiet(self: *Driver, ms: i64) !void {
        const until = now() + ms;
        while (now() < until) try self.drain(10);
    }

    /// 等待子进程退出（最长 10 秒），并校验：退出码、终端 termios 与 fcntl 标志已恢复，输出中没有 OSC 52 剪贴板写入或测试密钥。
    fn finish(self: *Driver, expected: c_int) !void {
        const until = now() + 10000;
        while (self.owned and now() < until) try self.drain(20);
        try check(!self.owned);
        // waitpid 状态的退出码位于高 8 位，因此与 expected << 8 比较。
        try check(self.status == expected << 8);

        try self.drain(0);

        var restored: abi.Termios = undefined;
        try check(abi.tcgetattr(self.slave, &restored) == 0);
        try check(std.meta.eql(self.original, restored));
        // F_GETFL (3)：确认 slave 的文件状态标志已恢复为启动前的值。
        try check(c.fcntl(self.slave, 3) == self.flags);

        // Regular TUI must never switch buffers, address absolute cells,
        // erase the display, or install a scrolling region (including resize).
        try regular.rejectFullscreen(self.output[0..self.used]);

        // 安全检查：应用不得输出 OSC 52 剪贴板序列，也不得泄露测试注入的密钥。
        try check(std.mem.indexOf(u8, self.output[0..self.used], "\x1b]52;") == null);
        try check(std.mem.indexOf(u8, self.output[0..self.used], "fixture-secret-never-log") == null);
        const prefix = "thin --resume ";
        const bytes = self.output[0..self.used];
        try check(std.mem.indexOf(u8, bytes, "Session ID: ") == null);
        try check(std.mem.indexOf(u8, bytes, "Resume: ") == null);
        const at = std.mem.indexOf(u8, bytes, prefix);
        if (expected == 0 and at != null) {
            try check(at.? + prefix.len + 32 <= bytes.len);
            const id = bytes[at.? + prefix.len ..][0..32];
            for (id) |byte| try check((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'));
            try check(std.mem.indexOf(u8, bytes[at.? + prefix.len + 32 ..], prefix) == null);
            const leave = "\x18\x1b[0m\x1b[?2004l\x1b[?2026l\x1b[?25h\r\n";
            // Restored OPOST/ONLCR may add an extra CR before LF.
            const translated_leave = "\x18\x1b[0m\x1b[?2004l\x1b[?2026l\x1b[?25h\r\r\n";
            const exit_at = std.mem.lastIndexOf(u8, bytes[0..at.?], leave) orelse std.mem.lastIndexOf(u8, bytes[0..at.?], translated_leave);
            try check(exit_at != null);
            const after_leave = exit_at.? + (if (std.mem.startsWith(u8, bytes[exit_at.?..], leave)) leave.len else translated_leave.len);
            // Only the terminal leave, a blank separator, the green command and
            // its reset may follow; no other escape or stray byte.
            const theme = @import("../ui/theme.zig");
            var expected_buffer: [128]u8 = undefined;
            const expected_tail = std.fmt.bufPrint(&expected_buffer, "\n{s}thin --resume {s}{s}\n", .{ theme.success, id, theme.reset }) catch unreachable;
            var translated_buffer: [128]u8 = undefined;
            const translated_tail = std.fmt.bufPrint(&translated_buffer, "\r\n{s}thin --resume {s}{s}\r\n", .{ theme.success, id, theme.reset }) catch unreachable;
            try check(std.mem.eql(u8, bytes[after_leave..], expected_tail) or std.mem.eql(u8, bytes[after_leave..], translated_tail));
            // Only validated immutable metadata leaves this capture buffer.
            std.debug.print("PTY_SESSION_ID={s}\n", .{id});
        } else try check(at == null); // Signal/headless exits do not announce it.
    }

    /// 清理：若子进程仍归本驱动器所有，则 SIGKILL 进程组与进程本身，并在 2 秒内尝试回收；最后关闭两端 fd。
    fn deinit(self: *Driver) void {
        if (self.owned) {
            // The child remains unreaped, hence its PID/group cannot be reused.
            if (getpgid(self.pid) == self.pid) _ = kill(-self.pid, 9);
            _ = kill(self.pid, 9); // Also covers failure before setsid.

            const until = now() + 2000;
            while (self.owned and now() < until) {
                const result = waitpid(self.pid, &self.status, 1);
                if (result == self.pid or (result < 0 and c._errno().* == 10)) {
                    self.owned = false;
                    break;
                }
                if (result < 0 and c._errno().* != 4) break;
                // fd 为 -1 的 pollfd 会被 poll 忽略，因此这里充当 5 毫秒的休眠。
                var descriptors = [_]c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
                _ = c.poll(&descriptors, 1, 5);
            }

            // 超时仍未确认回收时只打印警告，不再无限阻塞。
            if (self.owned) std.debug.print("PTY_CHILD_CLEANUP_UNCONFIRMED pid={d}\n", .{self.pid});
        }

        // PTY 两端的关闭与子进程是否回收无关，始终执行。
        _ = c.close(self.master);
        _ = c.close(self.slave);
    }
};

/// 读取必需的环境变量；缺失时返回 FixtureEnvironmentRequired。
fn required(init: std.process.Init, key: []const u8) ![]const u8 {
    return init.environ_map.get(key) orelse error.FixtureEnvironmentRequired;
}

/// Exact configured-effort hues, not a visual guess from an animated request.
fn settingsColor(d: *const Driver, start: usize, level: []const u8) !void {
    const color: []const u8 = if (std.mem.eql(u8, level, "off")) "\x1b[38;5;245m" else if (std.mem.eql(u8, level, "low")) "\x1b[38;5;114m" else if (std.mem.eql(u8, level, "high")) "\x1b[38;5;75m" else if (std.mem.eql(u8, level, "max")) "\x1b[38;5;177m" else return error.UnknownSettingsLevel;
    const bytes = d.output[start..d.used];
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, from, color)) |at| {
        from = at + color.len;
        const model_end = "fixture-model\x1b[0m ";
        if (!std.mem.startsWith(u8, bytes[from..], model_end)) continue;
        const slot = bytes[from + model_end.len ..];
        // A level confirmation keeps effort color; an actual percentage uses
        // occupancy, independent of the model's configured effort.
        if (std.mem.startsWith(u8, slot, color) and std.mem.startsWith(u8, slot[color.len..], level) and std.mem.startsWith(u8, slot[color.len + level.len ..], "\x1b[0m) > ")) return;
        if (std.mem.startsWith(u8, slot, "\x1b[0m?%\x1b[0m) > ")) return;
        const green = "\x1b[38;5;114m";
        if (!std.mem.startsWith(u8, slot, green)) continue;
        var end = green.len;
        while (end < slot.len and (std.ascii.isDigit(slot[end]) or slot[end] == '.')) : (end += 1) {}
        if (!std.mem.startsWith(u8, slot[end..], "%\x1b[0m) > ")) continue;
        const percent = std.fmt.parseFloat(f64, slot[green.len..end]) catch continue;
        if (percent >= 0 and percent < 25) return;
    }
    return error.SettingsColorMismatch;
}

/// Each input waits for a new completed frame; sparse diffs need not reprint
/// unchanged labels. Assertions below inspect the replayed owned screen.
fn settingsKey(d: *Driver, bytes: []const u8) !void {
    const start = d.used;
    try d.send(bytes);
    try d.waitFrame(start, "\x1b[?25l");
}

fn settingsValues(d: *Driver, low: []const u8, decision: []const u8, selected: usize) !void {
    const view = try d.screen();
    var buffer: [100]u8 = undefined;
    try check(view.visible(try std.fmt.bufPrint(&buffer, "Low-price input  {s}", .{low})));
    try check(view.visible(try std.fmt.bufPrint(&buffer, "Decision model   {s}", .{decision})));
    try check(view.visible(if (selected == 0) "> Low-price input" else "> Decision model"));
}

fn settingsDecisionChoose(d: *Driver, name: []const u8, backwards: bool) !void {
    var buffer: [1200]u8 = undefined;
    const selected = try std.fmt.bufPrint(&buffer, "> {s}", .{name});
    for (0..64) |_| {
        const view = try d.screen();
        if (view.visible(selected)) return;
        try settingsKey(d, if (backwards) "\x1b[A" else "\x1b[B");
    }
    return error.DecisionChoiceUnavailable;
}

// The Node owner checks config.json CAS persistence and ignored legacy files;
// choices are exact model references, never a dedicated Jev preset.
// Omitted decision.enabled defaults on only when decision is configured.
fn globalSettings(d: *Driver, mode: []const u8) !void {
    const off = std.mem.eql(u8, mode, "settings-global-off");
    const on = std.mem.eql(u8, mode, "settings-global-on");
    const verify = std.mem.eql(u8, mode, "settings-global-verify");
    const absent = std.mem.eql(u8, mode, "settings-global-unconfigured");
    const native = std.mem.eql(u8, mode, "settings-global-native");
    try check(off or on or verify or absent or native);
    try d.waitIdle(0);
    try settingsKey(d, "/settings\r");
    const before = if (on) "off" else "on";
    const after = if (off) "off" else "on";
    const decision_before = if (absent or native or on) "Off" else "native/family/native-review";
    const decision_after = if (absent or off) "Off" else "native/family/native-review";
    try settingsValues(d, before, decision_before, 0);
    if (off or on) {
        try settingsKey(d, "\r");
        try settingsValues(d, after, decision_before, 0);
    }
    try settingsKey(d, "\x1b[B");
    try settingsValues(d, after, decision_before, 1);
    try settingsKey(d, "\r");
    const choice = try d.screen();
    try check(!choice.visible("OpenCode Jev Free") and !choice.visible("Logged-in model") and !choice.visible("Request timeout"));
    // The selected native row may be beyond the first bounded window. Verify
    // both exact choices are navigable, not that every candidate fits at once.
    try settingsDecisionChoose(d, "Off", false);
    try check((try d.screen()).visible("> Off"));
    try settingsDecisionChoose(d, "native/family/native-review", false);
    try check((try d.screen()).visible("> native/family/native-review"));
    try settingsKey(d, "\x1b[D");
    try settingsValues(d, after, decision_before, 1);
    try settingsKey(d, "\r");
    try settingsKey(d, "\x1b");
    try settingsValues(d, after, decision_before, 1);
    if (!verify) {
        try settingsKey(d, "\r");
        try settingsDecisionChoose(d, if (on or native) "native/family/native-review" else "Off", false);
        try settingsKey(d, "\r");
        try settingsValues(d, after, decision_after, 1);
    }
    try settingsKey(d, "\x1b[A");
    try settingsValues(d, after, decision_after, 0);
    // Left returns to the root command list with settings selected. Tab
    // completes it, and a separately acknowledged Enter opens it again.
    try settingsKey(d, "\x1b[D");
    const root = try d.screen();
    try check(root.visible("> /settings") and root.visible("/model") and !root.visible("Low-price input"));
    try settingsKey(d, "\t");
    const completed = try d.screen();
    try check(completed.visible("/settings"));
    try settingsKey(d, "\r");
    try settingsValues(d, after, decision_after, 0);
    const start = d.used;
    try d.send("\x1b");
    try d.waitIdle(start);
    const closed = try d.screen();
    try check(!closed.visible("Low-price input") and !closed.visible("Decision model"));
    // No fabricated L assertion: unknown pricing has no authoritative tier.
    // Reopening checks the owner's published values after Esc, not UI intent.
    try settingsKey(d, "/settings\r");
    try settingsValues(d, after, decision_after, 0);
    const close_start = d.used;
    try d.send("\x1b");
    try d.waitIdle(close_start);
}

// Node validates the saved whole JSON and request counts before releasing
// each owned gate. Marker emission follows a complete replayed UI frame.
fn decisionModelGate(d: *Driver, a: std.mem.Allocator, project: []const u8, name: []const u8) !void {
    const path = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "{s}/decision-model-release-{s}", .{ project, name }), 0);
    try check(access(path, 0) == -1 and c._errno().* == 2);
    std.debug.print("DECISION_MODEL_GATE={s}\n", .{name});
    const until = now() + 10000;
    while (now() < until) {
        if (access(path, 0) == 0) return;
        try check(c._errno().* == 2);
        try d.drain(20);
        if (!d.owned) return error.EarlyExit;
    }
    return error.DecisionModelGateTimeout;
}

// Screens are large: keep these extra acceptance helpers off the main stack.
fn decisionModelScreen(d: *Driver, a: std.mem.Allocator, required_text: []const []const u8, hidden: []const []const u8) !void {
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    view.* = .{};
    try view.replay(d.output[0..d.used]);
    for (required_text) |needle| try check(view.visible(needle));
    for (hidden) |needle| try check(!view.visible(needle));
}

fn decisionModel(d: *Driver, init: std.process.Init, mode: []const u8, project: []const u8) !void {
    const a = init.arena.allocator();
    const backwards = std.mem.eql(u8, mode, "settings-decision-model-wrap");
    try check(backwards or std.mem.eql(u8, mode, "settings-decision-model-down") or std.mem.eql(u8, mode, "settings-decision-model-native"));
    try d.waitIdle(0);
    var start = d.used;
    try d.send("decision-warmup-history-private-marker\r");
    try d.waitText(start, "decision-warmup-answer");
    try d.waitIdle(start);
    try settingsKey(d, "/settings\r");
    try settingsKey(d, "\x1b[B");
    try decisionModelScreen(d, a, &.{"> Decision model"}, &.{});
    try settingsKey(d, "\r");
    try decisionModelScreen(d, a, &.{ "> Off", "aux/family/judge", "primary/fixture-main", "Search> " }, &.{ "locked/secret-model", "OpenCode Jev Free", "Logged-in model", "Request timeout" });
    try decisionModelGate(d, a, project, "opened");
    try settingsDecisionChoose(d, "aux/family/judge", backwards);
    // A pasted identity plus Enter cannot save or fabricate a candidate.
    try d.send("\x1b[200~locked/secret-model\x1b[201~\r");
    try d.quiet(150);
    try decisionModelScreen(d, a, &.{"aux/family/judge"}, &.{ "locked/secret-model", "Decision model selected" });
    try settingsKey(d, "\x1b");
    try decisionModelScreen(d, a, &.{"> Decision model"}, &.{"Search> "});
    try decisionModelGate(d, a, project, "canceled");

    try settingsKey(d, "\r");
    try settingsDecisionChoose(d, "aux/family/judge", backwards);
    try decisionModelScreen(d, a, &.{ "> aux/family/judge", "Search> " }, &.{"locked/secret-model"});
    // Search intersects provider and raw-ID tokens, case-insensitively. A query
    // with no candidates cannot invent a choice or save on Enter.
    try settingsKey(d, "missing-decision-query");
    try decisionModelScreen(d, a, &.{ "Search> missing-decision-query", "No matching models" }, &.{ "> Off", "aux/family/judge", "primary/fixture-main" });
    try d.send("\r");
    try d.quiet(30);
    try decisionModelScreen(d, a, &.{"No matching models"}, &.{"Decision model   aux/family/judge"});
    try settingsKey(d, "\x15AUX /JUDGE");
    try decisionModelScreen(d, a, &.{ "Search> AUX /JUDGE", "> aux/family/judge" }, &.{ "> Off", "primary/fixture-main", "locked/secret-model", "No matching models" });
    // Settings now returns a generic Ready notice. Authorize success from the
    // completed owner-published frame and the following whole-JSON gate, not a
    // removed selection-specific caption.
    try settingsKey(d, "\r");
    try decisionModelScreen(d, a, &.{ "> Decision model", "Decision model   aux/family/judge" }, &.{ "Search> ", "Logged-in model", "AUX /JUDGE", "missing-decision-query" });
    try decisionModelGate(d, a, project, "selected");
    start = d.used;
    try d.send("\x1b");
    try d.waitIdle(start);
    try decisionModelScreen(d, a, &.{"fixture-main"}, &.{ "family/judge", "AUX /JUDGE", "missing-decision-query" });
    start = d.used;
    try d.send("decision-normal-task-private-marker\r");
    // The server only emits this AFTER inspecting the canonical bash result,
    // not when a command preview or ready caption happens to become visible.
    try d.waitFrame(start, "decision-tool-result-verified");
    try d.waitIdle(start);
    try check(std.mem.indexOf(u8, d.output[start..d.used], "Approval #") == null);
    try decisionModelScreen(d, a, &.{"fixture-main"}, &.{});
}

// Image selection owns separate ACKed gates; no timer stands in for a save.
fn imageModelGate(d: *Driver, a: std.mem.Allocator, project: []const u8, name: []const u8) !void {
    const path = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "{s}/image-model-release-{s}", .{ project, name }), 0);
    try check(access(path, 0) == -1 and c._errno().* == 2);
    std.debug.print("IMAGE_MODEL_GATE={s}\n", .{name});
    const until = now() + 10000;
    while (now() < until) {
        if (access(path, 0) == 0) return;
        try check(c._errno().* == 2);
        try d.drain(20);
        if (!d.owned) return error.EarlyExit;
    }
    return error.ImageModelGateTimeout;
}

fn imageModel(d: *Driver, init: std.process.Init, project: []const u8) !void {
    const a = init.arena.allocator();
    try d.waitIdle(0);
    var start = d.used;
    try d.send("image-warmup-history-private-marker\r");
    try d.waitText(start, "image-warmup-answer");
    try d.waitIdle(start);
    try settingsKey(d, "/settings\r");
    // Preserve the seven original positions; Image is appended at index 7.
    for (0..7) |_| try settingsKey(d, "\x1b[B");
    try decisionModelScreen(d, a, &.{ "> Image model", "Image model      Off" }, &.{});
    try settingsKey(d, "\r");
    try decisionModelScreen(d, a, &.{ "> Off", "aux/deepseek-flash", "Search> " }, &.{ "primary/fixture-main", "locked/deepseek-flash", "aux/not-image" });
    try imageModelGate(d, a, project, "opened");
    try settingsKey(d, "aux/deepseek-flash");
    try decisionModelScreen(d, a, &.{"> aux/deepseek-flash"}, &.{});
    try settingsKey(d, "\x1b");
    try decisionModelScreen(d, a, &.{"> Image model"}, &.{"Search> "});
    try imageModelGate(d, a, project, "canceled");
    try settingsKey(d, "\r");
    try settingsKey(d, "aux/deepseek-flash");
    try decisionModelScreen(d, a, &.{"> aux/deepseek-flash"}, &.{});
    try settingsKey(d, "\r");
    try decisionModelScreen(d, a, &.{ "> Image model", "aux/deepseek-flash" }, &.{"Search> "});
    try imageModelGate(d, a, project, "selected");
    start = d.used;
    try d.send("\x1b");
    try d.waitIdle(start);
    start = d.used;
    try d.send("image-normal-task-private-marker\r");
    try d.waitFrame(start, "image-tool-result-verified");
    try d.waitIdle(start);
    try settingsKey(d, "/settings\r");
    for (0..7) |_| try settingsKey(d, "\x1b[B");
    try decisionModelScreen(d, a, &.{"> Image model"}, &.{});
    try settingsKey(d, "\r");
    try settingsKey(d, "\x15Off");
    try decisionModelScreen(d, a, &.{"> Off"}, &.{"aux/deepseek-flash"});
    try settingsKey(d, "\r");
    try decisionModelScreen(d, a, &.{ "> Image model", "Image model      Off" }, &.{"Search> "});
    try imageModelGate(d, a, project, "off");
    start = d.used;
    try d.send("\x1b");
    try d.waitIdle(start);
    // A subsequent explicit request proves Off actually removes the tool.
    start = d.used;
    try d.send("image-off-proof\r");
    try d.waitFrame(start, "image-off-verified");
    try d.waitIdle(start);
}

// Shared request-timeout and main-preference journey, with direct Decision choices.
fn settingsValueGate(d: *Driver, a: std.mem.Allocator, project: []const u8, name: []const u8) !void {
    const raw = try std.fmt.allocPrint(a, "{s}/settings-values-release-{s}", .{ project, name });
    defer a.free(raw);
    const path = try a.dupeSentinel(u8, raw, 0);
    defer a.free(path);
    try check(access(path, 0) == -1 and c._errno().* == 2);
    std.debug.print("SETTINGS_VALUES_GATE={s}\n", .{name});
    const until = now() + 5000;
    while (now() < until) {
        if (access(path, 0) == 0) return;
        try check(c._errno().* == 2);
        try d.drain(5);
        if (!d.owned) return error.EarlyExit;
    }
    return error.SettingsValueGateTimeout;
}

// Bounded candidate navigation, not fixed preset indices: current custom values
// may insert another row. Heap screen avoids inflating the acceptance stack.
fn settingsValueSelect(d: *Driver, a: std.mem.Allocator, label: []const u8) !void {
    const needle = try std.fmt.allocPrint(a, "> {s}", .{label});
    defer a.free(needle);
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    for (0..12) |_| {
        view.* = .{};
        try view.replay(d.output[0..d.used]);
        if (view.visible(needle)) return;
        try settingsKey(d, "\x1b[B");
    }
    return error.SettingsValueCandidateMissing;
}

fn settingsValueMenuOrder(d: *Driver, a: std.mem.Allocator, labels: []const []const u8) !void {
    for (labels) |label| {
        const selected = try std.fmt.allocPrint(a, "> {s}", .{label});
        defer a.free(selected);
        try decisionModelScreen(d, a, &.{selected}, &.{});
        try settingsKey(d, "\x1b[B");
    }
}

fn settingsValueOpen(d: *Driver, a: std.mem.Allocator, label: []const u8) !void {
    try settingsValueSelect(d, a, label);
    try settingsKey(d, "\r");
}

fn settingsValueChoose(d: *Driver, a: std.mem.Allocator, label: []const u8, parent: []const u8) !void {
    try settingsValueOpen(d, a, label);
    const selected = try std.fmt.allocPrint(a, "> {s}", .{parent});
    defer a.free(selected);
    try decisionModelScreen(d, a, &.{selected}, &.{"Custom ("});
}

fn settingsValuesJourney(d: *Driver, init: std.process.Init, project: []const u8) !void {
    const a = init.arena.allocator();
    try d.waitIdle(0);
    var start = d.used;
    try d.send("values-warmup-private-marker\r");
    try d.waitText(start, "values-warmup-answer");
    try d.waitIdle(start);
    try settingsKey(d, "/settings\r");
    try decisionModelScreen(d, a, &.{ "> Low-price input", "Decision model", "Auto compaction", "Command timeout", "Request timeout", "Output limit", "Task timeout" }, &.{});
    try settingsValueMenuOrder(d, a, &.{ "Low-price input", "Decision model", "Auto compaction", "Command timeout", "Request timeout", "Output limit", "Task timeout" });
    try settingsValueGate(d, a, project, "opened");
    try settingsValueOpen(d, a, "Auto compaction"); // Boolean toggle, no numeric picker.
    try decisionModelScreen(d, a, &.{ "> Auto compaction", "Auto compaction  off" }, &.{});
    try settingsValueGate(d, a, project, "compaction");

    try settingsValueOpen(d, a, "Command timeout");
    try decisionModelScreen(d, a, &.{ "> 123.456 s (current)", "Custom (s)..." }, &.{});
    try settingsValueGate(d, a, project, "current");
    try settingsValueOpen(d, a, "Custom (s)...");
    try decisionModelScreen(d, a, &.{ "Custom: _ s", "up to 3 decimals", "Enter stages" }, &.{});
    // Invalid candidates may intentionally have no confirmable ACK and emit
    // no new frame on Enter. Observe the existing screen, not waitFrame.
    try d.send("\r");
    try d.quiet(30);
    try decisionModelScreen(d, a, &.{"Custom: _ s"}, &.{"(staged)"});
    try settingsValueGate(d, a, project, "invalid-empty");
    try settingsKey(d, "0");
    try d.send("\r");
    try d.quiet(30);
    try decisionModelScreen(d, a, &.{"Custom: 0_ s"}, &.{"(staged)"});
    try settingsValueGate(d, a, project, "invalid-zero");
    try settingsKey(d, "\x15"); // Ctrl-U must clear all digits, not edit the composer.
    try decisionModelScreen(d, a, &.{"Custom: _ s"}, &.{});
    try settingsKey(d, "4294967.296"); // Same u32-ms overflow, expressed in seconds.
    try d.send("\r");
    try d.quiet(30);
    try decisionModelScreen(d, a, &.{"Custom: 4294967.296_ s"}, &.{"(staged)"});
    try settingsValueGate(d, a, project, "invalid-overflow");
    try settingsKey(d, "\x1b[D"); // edit -> candidate list, not parent Settings.
    try decisionModelScreen(d, a, &.{"> Custom (s)..."}, &.{"Custom:"});
    try settingsValueGate(d, a, project, "edit-cancel");
    try settingsKey(d, "\r");
    try decisionModelScreen(d, a, &.{"Custom: _ s"}, &.{});
    try settingsKey(d, "120.001");
    // Two Enters in ONE input batch must only stage. The owner drops remaining
    // batch input, publishes a fresh generation, and waits for its frame ACK.
    try settingsKey(d, "\r\r");
    try decisionModelScreen(d, a, &.{"> 120.001 s (staged)"}, &.{"Custom:"});
    try settingsValueGate(d, a, project, "staged-cancel");
    try settingsKey(d, "\x1b"); // staged candidate -> parent, no save.
    try decisionModelScreen(d, a, &.{"> Command timeout"}, &.{"Custom ("});
    try settingsValueGate(d, a, project, "canceled");

    try settingsValueOpen(d, a, "Command timeout");
    try decisionModelScreen(d, a, &.{"> 123.456 s (current)"}, &.{"120.001 s"});
    try settingsValueOpen(d, a, "Custom (s)...");
    try settingsKey(d, "120");
    try settingsKey(d, "\r\r");
    try decisionModelScreen(d, a, &.{"> 120 s (staged)"}, &.{"Custom:"});
    try settingsValueGate(d, a, project, "command-staged");
    try settingsKey(d, "\r"); // Separate Enter only after fresh ACK and disk gate.
    try decisionModelScreen(d, a, &.{ "> Command timeout", "120 s" }, &.{"Custom ("});
    try settingsValueGate(d, a, project, "command");

    try settingsValueOpen(d, a, "Request timeout");
    try decisionModelScreen(d, a, &.{"> 10 s (current)"}, &.{});
    try settingsValueChoose(d, a, "60 s", "Request timeout");
    try settingsValueGate(d, a, project, "request");
    try settingsValueOpen(d, a, "Output limit");
    try decisionModelScreen(d, a, &.{"> 100 tokens (current)"}, &.{});
    try settingsValueChoose(d, a, "4096 tokens", "Output limit");
    try settingsValueGate(d, a, project, "output");
    try settingsValueOpen(d, a, "Output limit");
    try settingsValueChoose(d, a, "Auto", "Output limit");
    try settingsValueGate(d, a, project, "output-auto");
    try settingsValueOpen(d, a, "Output limit");
    try decisionModelScreen(d, a, &.{"> Auto (current)"}, &.{});
    try settingsValueChoose(d, a, "4096 tokens", "Output limit");
    try settingsValueGate(d, a, project, "output-restored");
    try settingsValueOpen(d, a, "Task timeout");
    try settingsValueChoose(d, a, "900 s", "Task timeout");
    try settingsValueGate(d, a, project, "task");

    try settingsValueOpen(d, a, "Decision model");
    try decisionModelScreen(d, a, &.{ "> aux/family/judge", "Off", "primary/fixture-main" }, &.{ "OpenCode Jev Free", "Logged-in model", "Request timeout" });
    try settingsValueGate(d, a, project, "decision-menu");
    try settingsKey(d, "\x1b[D"); // decision -> root Settings.
    try decisionModelScreen(d, a, &.{"> Decision model"}, &.{"Logged-in model"});
    try settingsKey(d, "\x1b[D"); // Settings -> root commands.
    try decisionModelScreen(d, a, &.{"> /settings"}, &.{"Low-price input"});
    start = d.used;
    try d.send("\x1b");
    try d.waitIdle(start);
    try decisionModelScreen(d, a, &.{"fixture-main"}, &.{"family/judge"});
    // Back-to-commands deliberately restores "/". Esc dismisses that menu
    // without discarding the user's input; clear it before a normal prompt.
    try settingsKey(d, "\x15");
    try settingsValueGate(d, a, project, "closed");
    start = d.used;
    try d.send("values-task-private-marker\r");
    try d.waitFrame(start, "values-tool-result-verified");
    try d.waitIdle(start);
    try check(std.mem.indexOf(u8, d.output[start..d.used], "Approval #") == null);
    try decisionModelScreen(d, a, &.{"fixture-main"}, &.{});
}

// Whole-capture replay through the last ACK, not a suffix that loses native
// scrollback or an in-flight frame. Keep this large fixture off the stack.
fn approvalCancelScreen(d: *Driver, view: *regular.Screen) !void {
    const raw = d.output[0..d.used];
    const ack = std.mem.lastIndexOf(u8, raw, "\x1b[?25h") orelse return error.MissingApprovalCancelAck;
    view.* = .{};
    try view.replay(raw[0 .. ack + "\x1b[?25h".len]);
}

fn checkApprovalCancelRestored(view: *const regular.Screen) !void {
    std.debug.print("APPROVAL_CANCEL_SCREEN last_visible={any} prior_total={d} history={d}\n", .{ view.visible("PRIOR-CANCEL-17"), view.count("PRIOR-CANCEL-"), view.history_len });
    try check(view.visible("PRIOR-CANCEL-17"));
    var marker: [32]u8 = undefined;
    var visible_prior: usize = 0;
    for (0..18) |i| {
        const text = try std.fmt.bufPrint(&marker, "PRIOR-CANCEL-{d:0>2}", .{i});
        // count includes history AND grid: restore must not reprint old rows.
        try check(view.count(text) == 1);
        if (view.visible(text)) visible_prior += 1;
    }
    try check(view.count("Approval #") == 0 and view.count("GHOST-CANCEL-ONLY") == 0);
    try check(view.row == 23);
    const composer = &view.grid[23];
    try check(std.mem.indexOf(u8, composer, ") > ") != null);
    const tail = std.mem.trimEnd(u8, composer, " ");
    try check(view.col == tail.len + @as(usize, if (std.mem.endsWith(u8, tail, ") >")) 1 else 0));
    // Catch the original screenful of erased body, not just a surviving tail
    // marker. This compact fixture leaves many prior lines in the viewport.
    try check(visible_prior >= 8);
    var occupied: usize = 0;
    var blanks: usize = 0;
    var longest_blank: usize = 0;
    for (view.grid[0..23]) |row| {
        if (std.mem.trim(u8, &row, " ").len == 0) {
            blanks += 1;
            longest_blank = @max(longest_blank, blanks);
        } else {
            occupied += 1;
            blanks = 0;
        }
    }
    try check(occupied >= 10 and longest_blank <= 5);
}

fn approvalCancel(d: *Driver) !void {
    const a = std.heap.page_allocator;
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    try d.waitIdle(0);
    var start = d.used;
    try d.send("approval-cancel-seed\r");
    try queuedScreen(d, a, start, &.{"PRIOR-CANCEL-17"});
    try queuedIdle(d, a, start);
    try approvalCancelScreen(d, view);
    try check(view.visible("PRIOR-CANCEL-17"));
    for (0..18) |i| {
        var marker: [32]u8 = undefined;
        try check(view.count(try std.fmt.bufPrint(&marker, "PRIOR-CANCEL-{d:0>2}", .{i})) == 1);
    }

    start = d.used;
    try d.send("approval-cancel-long\r");
    try queuedScreen(d, a, start, &.{ "Approval #", "GHOST-CANCEL-ONLY" });
    try approvalCancelScreen(d, view);
    const history_before = view.history_len;
    const waiting = d.used;
    try d.quiet(2400);
    try check(d.owned);
    const titles = std.mem.count(u8, d.output[waiting..d.used], "Approval #");
    try approvalCancelScreen(d, view);
    try check(titles == 0 and view.history_len == history_before);
    try check(view.count("Approval #") == 1 and view.visible("GHOST-CANCEL-ONLY"));
    std.debug.print("APPROVAL_CANCEL_WAIT repeated_titles={d}\n", .{titles});

    // Standalone ESC: no following byte may mask the parser's 150ms expiry.
    start = d.used;
    try d.send("\x1b");
    try queuedScreen(d, a, start, &.{"Canceled"});
    try queuedIdle(d, a, start);
    try approvalCancelScreen(d, view);
    try checkApprovalCancelRestored(view);
    start = d.used;
    try d.send("cancel-live-draft");
    try queuedScreen(d, a, start, &.{"cancel-live-draft"});
    try approvalCancelScreen(d, view);
    try checkApprovalCancelRestored(view);
    try check(std.mem.endsWith(u8, std.mem.trimEnd(u8, &view.grid[23], " "), "cancel-live-draft"));
    start = d.used;
    try d.send("\x15");
    try queuedIdle(d, a, start);
    try approvalCancelScreen(d, view);
    try checkApprovalCancelRestored(view);
    try check(std.mem.endsWith(u8, std.mem.trimEnd(u8, &view.grid[23], " "), ") >"));
    std.debug.print("APPROVAL_CANCEL_GATE=verified\n", .{});
}

fn localCommand(d: *Driver, mode: []const u8) !void {
    // Do not materialize another large Screen on this history driver's stack.
    errdefer std.debug.print("command PTY tail: {s}\n", .{d.output[d.used -| 3000..d.used]});
    try d.waitIdle(0);
    const accept = std.mem.eql(u8, mode, "settings-command-accept");
    const deny = std.mem.eql(u8, mode, "settings-command-deny");
    const cancel = std.mem.eql(u8, mode, "settings-command-cancel");
    const timeout = std.mem.eql(u8, mode, "settings-command-timeout");
    const stable = std.mem.eql(u8, mode, "settings-command-stable");
    try check(accept or deny or cancel or timeout or stable);
    if (stable) {
        var source: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer source.deinit();
        try source.writer.writeAll("  !rm -rf absent; touch stable-executed; #");
        for (0..125) |i| try source.writer.print(" synthetic-step-{d}: 中文注释 abcdefghijklmnopqrstuvwxyz", .{i});
        try source.writer.writeByte('\r');
        const submitted = d.used;
        try d.send(source.written());
        try d.waitFrame(submitted, "Approval #");
        const view = try std.heap.page_allocator.create(regular.Screen);
        defer std.heap.page_allocator.destroy(view);
        const ack_before = std.mem.lastIndexOf(u8, d.output[0..d.used], "\x1b[?25h").? + "\x1b[?25h".len;
        view.* = .{};
        try view.replay(d.output[0..ack_before]);
        const history_before = view.history_len;
        try check(view.visible("Approval #"));
        const waiting = d.used;
        try d.quiet(2400);
        try check(d.owned);
        const titles = std.mem.count(u8, d.output[waiting..d.used], "Approval #");
        const ack_after = std.mem.lastIndexOf(u8, d.output[0..d.used], "\x1b[?25h").? + "\x1b[?25h".len;
        view.* = .{};
        try view.replay(d.output[0..ack_after]);
        std.debug.print("APPROVAL_WAIT repeated_titles={d} history_delta={d} visible_titles={d}\n", .{ titles, view.history_len -| history_before, view.count("Approval #") });
        try check(titles == 0 and view.history_len == history_before and view.count("Approval #") == 1);
        // An actual scroll still redraws and needs a fresh completed frame;
        // freezing idle animation must not freeze input or approval controls.
        const scrolled = d.used;
        try d.send("\x1b[B");
        try d.waitFrame(scrolled, "Approval #");
        const armed = d.used;
        try d.send("\t");
        try d.waitFrame(armed, "Approval #");
        const denied = d.used;
        try d.send("n");
        try d.waitIdle(denied);
        return;
    }
    // Empty command, bracketed paste and submit batch tail must not execute.
    if (deny) {
        var start = d.used;
        try d.send("!\r");
        try d.waitIdle(start);
        start = d.used;
        try d.send("\x1b[200~!touch pasted\n\x1b[201~");
        try d.quiet(150);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Approval #") == null);
        try d.send("\x15");
        try d.quiet(100);
    }
    // Ordinary CLI tools need no approval. A recursive deletion of an
    // absent owned relative target deliberately exercises mandatory approval.
    const command = if (accept) "printf 'OUT\\n'; printf 'ERR\\n' >&2; touch marker; rm -rf absent; exit 7" else if (deny) "rm -rf absent; touch denied" else "rm -rf absent; sleep 30 & echo $! > child; touch started; wait";
    var line: [256]u8 = undefined;
    const start = d.used;
    // Prefix whitespace follows the same dispatch semantics as the composer.
    try d.send(try std.fmt.bufPrint(&line, "  !{s}\r", .{command}));
    // Both command preview and approval must belong to a completed new frame.
    try d.waitFrame(start, command);
    try d.waitFrame(start, "Approval #");
    // Ordinary text (including y/n) belongs to the queue composer. Tab arms
    // the separate one-shot approval controls, then await their fresh frame.
    const armed = d.used;
    try d.send("\t");
    try d.waitFrame(armed, "Approval #");
    const answered = d.used;
    try d.send(if (deny) "n" else "y");
    if (cancel) {
        try d.quiet(200);
        try d.send("\x1b");
        try d.waitText(answered, "Canceled");
    }
    try d.waitIdle(answered);
    if (accept) {
        // These labels do not occur in the command preview. They prove that
        // actual local output is visible before any subsequent inference.
        try d.waitFrame(answered, "stdout:");
        try d.waitFrame(answered, "stderr:");
        try d.waitFrame(answered, "exit: 7");
        // Do not confuse OUT/ERR in the quoted command preview with actual
        // decoded stream lines. Keep the large screen off the driver's stack.
        const view = try std.heap.page_allocator.create(regular.Screen);
        defer std.heap.page_allocator.destroy(view);
        view.* = .{};
        try view.replay(d.output[0..d.used]);
        var stdout_line = false;
        var stderr_line = false;
        for (0..view.history_len + view.grid.len) |i| {
            const row = if (i < view.history_len) &view.history[i] else &view.grid[i - view.history_len];
            const value = std.mem.trim(u8, row, " \t");
            stdout_line = stdout_line or std.mem.eql(u8, value, "OUT");
            stderr_line = stderr_line or std.mem.eql(u8, value, "ERR");
        }
        try check(stdout_line and stderr_line);
        // Exactly one explicit subsequent inference; the mock validates the
        // preceding canonical bash call/result, including streams and exit 7.
        const normal = d.used;
        try d.send("command-normal-proof\r");
        try d.waitText(normal, "command-pair-verified");
        try d.waitIdle(normal);
    }
    if (deny) {
        const batch = d.used;
        try d.send("!rm -rf absent; touch batch-first\r!touch batch-tail\r");
        try d.waitFrame(batch, "Approval #");
        const deny_armed = d.used;
        try d.send("\t");
        try d.waitFrame(deny_armed, "Approval #");
        const rejected = d.used;
        try d.send("n");
        try d.waitIdle(rejected);
        try d.quiet(150);
        try check(std.mem.indexOf(u8, d.output[rejected..d.used], "Approval #") == null);
    }
}

/// 验收入口：从环境变量读取二进制、项目目录、HOME 与测试 URL，创建 PTY 并 fork 启动应用，再按 THIN_APP_TEST_MODE 驱动对应的交互场景。
// Tool-preview fixture handshakes are emitted only after replaying a complete
// cursor-ACK frame. Node keeps the SSE response open until each owned gate.
extern "c" fn access([*:0]const u8, c_int) c_int;

fn previewAbsent(path: [*:0]const u8) !void {
    try check(access(path, 0) == -1 and c._errno().* == 2);
}

fn previewFrame(d: *Driver, a: std.mem.Allocator, start: usize, needle: []const u8, pending: bool) !void {
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    const until = now() + 10000;
    while (now() < until) {
        try d.drain(20);
        const raw = d.output[0..d.used];
        const ack = std.mem.lastIndexOf(u8, raw, "\x1b[?25h") orelse continue;
        if (ack < start) continue;
        const complete = raw[0 .. ack + "\x1b[?25h".len];
        view.* = .{};
        try view.replay(complete);
        if (!view.visible(needle)) continue;
        try check(view.count(needle) == 1);
        var matched = false;
        for (0..view.history_len + view.grid.len) |i| {
            const row = if (i < view.history_len) &view.history[i] else &view.grid[i - view.history_len];
            if (std.mem.indexOf(u8, row, needle) == null) continue;
            const line = std.mem.trim(u8, row, " ");
            // Normal tool rows occupy at most floor(80 * .8) cells.
            try check(std.mem.trimEnd(u8, row, " ").len <= 64);
            if (pending) try check(std.mem.startsWith(u8, line, "w "));
            matched = true;
        }
        try check(matched);
        if (pending) {
            // Name/field preview is static neutral, never warm execution UI.
            const expected = try std.fmt.allocPrint(a, "w{s} ", .{spinner_theme.muted});
            defer a.free(expected);
            try check(std.mem.indexOf(u8, complete[start..], expected) != null);
        }
        for ([_][]const u8{ "receiving arguments", "Preparing write", "PREVIEW_RAW_CONTENT_SECRET" }) |hidden|
            try check(std.mem.indexOf(u8, complete, hidden) == null);
        return;
    }
    return error.ToolPreviewFrameTimeout;
}

fn toolPreview(d: *Driver, init: std.process.Init, mode: []const u8, project: []const u8) !void {
    const a = init.arena.allocator();
    const target = try a.dupeSentinel(u8, try std.fs.path.join(a, &.{ project, "preview-owned.txt" }), 0);
    const canceled = std.mem.eql(u8, mode, "tool-preview-cancel");
    try d.waitIdle(0);
    const start = d.used;
    try d.send("preview-task\r");
    try previewFrame(d, a, start, "write_file", true);
    try previewAbsent(target);
    std.debug.print("PREVIEW_GATE=header\n", .{});
    // The server now sends an unclosed path. A bounded observation window
    // proves it cannot leak the unreliable partial field into a normal row.
    try d.quiet(200);
    try previewFrame(d, a, start, "write_file", true);
    try check(std.mem.indexOf(u8, d.output[start..d.used], "preview-owned") == null);
    try previewAbsent(target);
    std.debug.print("PREVIEW_GATE=partial\n", .{});
    const path_start = d.used;
    try previewFrame(d, a, path_start, "preview-owned.txt", true);
    try previewAbsent(target);
    std.debug.print("PREVIEW_GATE=path-absent\n", .{});
    // Content is already arriving but the call remains unfinished at this gate.
    try d.quiet(250);
    try previewFrame(d, a, path_start, "preview-owned.txt", true);
    try previewAbsent(target);
    if (canceled) {
        const cancel_start = d.used;
        try d.send("\x1b");
        try d.waitIdle(cancel_start);
        try previewAbsent(target);
        std.debug.print("PREVIEW_GATE=canceled\n", .{});
    } else {
        std.debug.print("PREVIEW_GATE=finish\n", .{});
        const running = d.used;
        try d.waitFrame(running, "sleep 0.7");
        // A running *tool row*, not the busy composer, must have warm braille
        // and elapsed time before the owned sleep completes.
        const until = now() + 1500;
        var witnessed = false;
        while (now() < until and !witnessed) {
            try d.drain(10);
            const bytes = d.output[running..d.used];
            for (spinner_theme.command_pulse) |tone| {
                var from: usize = 0;
                while (std.mem.indexOfPos(u8, bytes, from, tone)) |at| {
                    from = at + tone.len;
                    const end = std.mem.indexOfPos(u8, bytes, from, "\x1b[K") orelse continue;
                    const line = bytes[from..end];
                    if (std.mem.indexOf(u8, line, "sleep 0.7") != null and
                        std.mem.indexOf(u8, line, "s\x1b[0m") != null and
                        std.mem.indexOf(u8, bytes[end..], "\x1b[?25h") != null) witnessed = true;
                }
            }
        }
        try check(witnessed);
        try d.waitFrame(start, "preview-final-answer");
        try d.waitIdle(start);
        try check(access(target, 0) == 0);
        try previewFrame(d, a, start, "preview-owned.txt", false);
        try previewFrame(d, a, start, "sleep 0.7", false);
    }
    for ([_][]const u8{ "receiving arguments", "Preparing write", "PREVIEW_RAW_CONTENT_SECRET", "preview-bash-proof" }) |hidden|
        try check(std.mem.indexOf(u8, d.output[start..d.used], hidden) == null);
    std.debug.print("PREVIEW_GATE=verified\n", .{});
}

// Queued product scenarios deliberately reuse the real fork/PTY/ACK helpers.
// Stage markers contain only fixed fixture names; captured terminal bytes stay
// in the owned project on failure, never in the parent console.
fn queuedFile(d: *Driver, a: std.mem.Allocator, project: []const u8, name: []const u8) !void {
    const path = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "{s}/{s}", .{ project, name }), 0);
    const until = now() + 15000;
    while (now() < until) {
        if (access(path, 0) == 0) return;
        try check(c._errno().* == 2);
        try d.drain(20);
        if (!d.owned) return error.EarlyExit;
    }
    return error.QueuedFileDeadline;
}

fn queuedGate(d: *Driver, a: std.mem.Allocator, project: []const u8, name: []const u8) !void {
    std.debug.print("QUEUED_GATE={s}\n", .{name});
    try queuedFile(d, a, project, try std.fmt.allocPrint(a, "release-{s}", .{name}));
}

// Replay only through the LAST complete cursor ACK, never an in-flight diff.
fn queuedScreen(d: *Driver, a: std.mem.Allocator, since: usize, needles: []const []const u8) !void {
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    const until = now() + 15000;
    while (now() < until) {
        try d.drain(20);
        const raw = d.output[0..d.used];
        if (std.mem.lastIndexOf(u8, raw, "\x1b[?25h")) |ack| {
            if (ack >= since) {
                view.* = .{};
                try view.replay(raw[0 .. ack + "\x1b[?25h".len]);
                var found = true;
                for (needles) |needle| found = found and view.visible(needle);
                if (found) return;
            }
        }
        if (!d.owned) return error.EarlyExit;
    }
    return error.QueuedScreenDeadline;
}

fn queuedKey(d: *Driver, a: std.mem.Allocator, bytes: []const u8, needles: []const []const u8) !void {
    const start = d.used;
    try d.send(bytes);
    try queuedScreen(d, a, start, needles);
}

fn queuedIdle(d: *Driver, a: std.mem.Allocator, since: usize) !void {
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    const until = now() + 15000;
    while (now() < until) {
        try d.drain(20);
        const raw = d.output[0..d.used];
        if (std.mem.lastIndexOf(u8, raw, "\x1b[?25h")) |ack| {
            if (ack >= since) {
                view.* = .{};
                try view.replay(raw[0 .. ack + "\x1b[?25h".len]);
                const row = &view.grid[view.row];
                if (std.mem.indexOf(u8, row, ") > ") != null or std.mem.startsWith(u8, row, "> ")) return;
            }
        }
        if (!d.owned) return error.EarlyExit;
    }
    return error.QueuedIdleDeadline;
}

fn queuedDraft(d: *Driver, a: std.mem.Allocator, text: []const u8) !void {
    const view = try a.create(regular.Screen);
    defer a.destroy(view);
    const until = now() + 15000;
    while (now() < until) {
        try d.drain(20);
        const raw = d.output[0..d.used];
        if (std.mem.lastIndexOf(u8, raw, "\x1b[?25h")) |ack| {
            view.* = .{};
            try view.replay(raw[0 .. ack + "\x1b[?25h".len]);
            const row = &view.grid[view.row];
            // Require the ENTIRE acknowledged editor tail, not recalled text
            // still visible in a pending row or an unrelated animation ACK.
            if (std.mem.lastIndexOf(u8, row, ") ")) |prefix| {
                if (prefix + 4 <= row.len and
                    std.mem.eql(u8, std.mem.trimEnd(u8, row[prefix + 4 ..], " "), text)) return;
            }
        }
        if (!d.owned) return error.EarlyExit;
    }
    return error.QueuedComposerDeadline;
}

fn queuedScenario(d: *Driver, init: std.process.Init, mode: []const u8, project: []const u8) !void {
    const a = init.arena.allocator();
    errdefer {
        const path = std.fmt.allocPrint(a, "{s}/queued-pty.log", .{project}) catch unreachable;
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = d.output[0..d.used] }) catch {};
    }
    const steer = std.mem.eql(u8, mode, "test-queued-steer");
    const withdraw = std.mem.eql(u8, mode, "test-queued-withdraw");
    const cancel = std.mem.eql(u8, mode, "test-queued-cancel");
    const natural = std.mem.eql(u8, mode, "test-queued-natural");
    try check(steer or withdraw or cancel or natural);
    try d.waitIdle(0);
    const start = d.used;
    try d.send("queued-start\r");
    if (withdraw) {
        try queuedScreen(d, a, start, &.{"queued-held"});
    } else {
        // A tool caption/argument preview is NOT execution evidence.
        try queuedFile(d, a, project, "started");
        if (natural) try queuedFile(d, a, project, "natural-awaiting");
        try d.waitBusy(start);
    }
    try queuedKey(d, a, "keep-steer\r", &.{"Steering pending #1: keep-steer"});
    try queuedDraft(d, a, "");
    try queuedKey(d, a, if (withdraw) "old-follow\x1b\r" else "keep-follow\x1b\r", &.{if (withdraw) "FollowUp pending #2: old-follow" else "FollowUp pending #2: keep-follow"});
    try queuedDraft(d, a, "");
    if (withdraw) {
        try queuedKey(d, a, "\x1b", &.{"old-follow"});
        try queuedDraft(d, a, "old-follow");
        try queuedGate(d, a, project, "withdrawn-follow");
        // Retyping after Ctrl-U and Enter creates a NEW Steering message.
        try queuedKey(d, a, "\x15new-steer\r", &.{"Steering pending #3: new-steer"});
        try queuedDraft(d, a, "");
        try queuedKey(d, a, "\x1b", &.{"new-steer"});
        try queuedDraft(d, a, "new-steer");
        // And a second recall can freely switch back to FollowUp.
        try queuedKey(d, a, "\x15new-follow\x1b\r", &.{"FollowUp pending #4: new-follow"});
        try queuedDraft(d, a, "");
    }
    if (steer or withdraw) {
        try queuedGate(d, a, project, "queued");
        try queuedScreen(d, a, start, &.{"queued-follow-answer"});
        try queuedIdle(d, a, start);
        try queuedGate(d, a, project, "done");
    } else {
        try queuedKey(d, a, "preserved-draft", &.{"preserved-draft"});
        // Opening drops the whole read tail: neither repetition nor Enter can
        // approve. The fresh replay must still show the safe default.
        try queuedKey(d, a, "\x03\x03\r", &.{"> Continue"});
        try queuedGate(d, a, project, "modal-default");
        // Each probe must cause an observable safe-selection transition.
        // Consecutive writes are NOT application read boundaries: without
        // these semantic ACKs a stop_feed tail could discard the later Esc.
        try queuedKey(d, a, "\x1b[B", &.{"> Stop and clear"});
        try queuedKey(d, a, "\x03\x03\r", &.{"> Continue"});
        try queuedKey(d, a, "\x1b[B", &.{"> Stop and clear"});
        try queuedKey(d, a, "\x1b[200~\r\x03\x1b[201~", &.{"> Continue"});
        try queuedKey(d, a, "\x1b", &.{ "Steering pending #1: keep-steer", "FollowUp pending #2: keep-follow", "preserved-draft" });
        try queuedDraft(d, a, "preserved-draft");
        try queuedGate(d, a, project, "modal-dismissed");
        try queuedKey(d, a, "\x03", &.{"> Continue"});
        if (natural) {
            const natural_start = d.used;
            // Node releases the already-in-flight final response after this ACK.
            try queuedGate(d, a, project, "natural-release");
            try queuedScreen(d, a, natural_start, &.{ "queued-natural-answer", "> Continue" });
            try queuedIdle(d, a, natural_start);
            try queuedGate(d, a, project, "natural-finished");
        }
        // Selection and Enter in one read must NOT approve. Only the next,
        // independent Enter after this complete dangerous-option ACK may act.
        try queuedKey(d, a, "\x1b[B\r", &.{"> Stop and clear"});
        try queuedGate(d, a, project, "selected-not-approved");
        const stop_start = d.used;
        try d.send("\r");
        try queuedIdle(d, a, stop_start);
        try queuedDraft(d, a, "preserved-draft");
        const cleared_view = try a.create(regular.Screen);
        defer a.destroy(cleared_view);
        cleared_view.* = .{};
        const cleared_raw = d.output[0..d.used];
        const cleared_ack = std.mem.lastIndexOf(u8, cleared_raw, "\x1b[?25h").?;
        try cleared_view.replay(cleared_raw[0 .. cleared_ack + "\x1b[?25h".len]);
        for ([_][]const u8{ "keep-steer", "keep-follow", "> Continue", "> Stop and clear" }) |text| try check(!cleared_view.visible(text));
        try queuedGate(d, a, project, "cleared");
        // A fresh explicit task proves stale confirmation cannot cancel a new
        // epoch. No queued message is allowed to sneak ahead of this probe.
        const probe_start = d.used;
        try d.send("\x15after-clear\r");
        try queuedScreen(d, a, probe_start, &.{"queued-probe-answer"});
        try queuedIdle(d, a, probe_start);
        try queuedGate(d, a, project, "done");
    }
    try d.send("\x04");
    try d.finish(0);
}

// Concrete entrypoints exported to the standalone dispatcher/build root.
pub fn testQueuedSteer(init: std.process.Init) !void {
    try main(init);
}
pub fn testQueuedWithdraw(init: std.process.Init) !void {
    try main(init);
}
pub fn testQueuedCancel(init: std.process.Init) !void {
    try main(init);
}
pub fn testQueuedNatural(init: std.process.Init) !void {
    try main(init);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const bin = try a.dupeSentinel(u8, try required(init, "THIN_APP_BIN"), 0);
    const project = try a.dupeSentinel(u8, try required(init, "THIN_APP_TEST_PROJECT"), 0);
    const home = try required(init, "THIN_APP_TEST_HOME");
    const url = try required(init, "THIN_APP_TEST_URL");

    // 测试 URL 必须指向本机 127.0.0.1 的 http 地址，且不能带 userinfo/query/fragment，防止测试误连外部服务。
    const uri = try std.Uri.parse(url);
    const host = uri.host orelse return error.UnsafeFixtureUrl;
    const host_text = switch (host) {
        .raw, .percent_encoded => |value| value,
    };
    try check(std.mem.eql(u8, uri.scheme, "http") and std.mem.eql(u8, host_text, "127.0.0.1") and uri.port != null and uri.port != 0 and uri.user == null and uri.password == null and uri.query == null and uri.fragment == null);
    try check(std.fs.path.isAbsolute(bin) and std.fs.path.isAbsolute(project) and std.fs.path.isAbsolute(home));

    // HOME 必须与进程环境中的 HOME 一致，保证应用读取的是测试目录。
    try check(std.mem.eql(u8, home, try required(init, "HOME")));

    const mode = try required(init, "THIN_APP_TEST_MODE");
    const home_env = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "HOME={s}", .{home}), 0);

    const full_resume = std.mem.startsWith(u8, mode, "resume-") and !std.mem.eql(u8, mode, "resume-create");
    const restore_error: ?[]const u8 = if (std.mem.eql(u8, mode, "restore-failure") or std.mem.eql(u8, mode, "resume-failure")) try required(init, "THIN_APP_TEST_RESTORE_ERROR") else null;
    if (restore_error) |expected| {
        try check(std.mem.eql(u8, expected, "SelectionNotFound") or std.mem.eql(u8, expected, "ApiKeyNotFound") or std.mem.eql(u8, expected, "SelectionEndpointUnavailable") or std.mem.eql(u8, expected, "ResumeNotFound") or std.mem.eql(u8, expected, "ResumeAuthenticationFailed") or std.mem.eql(u8, expected, "ResumeConflict") or std.mem.eql(u8, expected, "ResumeNotClosed") or std.mem.eql(u8, expected, "UnsupportedVersion") or std.mem.eql(u8, expected, "SessionInUse") or std.mem.eql(u8, expected, "InvalidResumeLength") or std.mem.eql(u8, expected, "InvalidJson"));
    }
    const restore_mode = std.mem.eql(u8, mode, "restore-selection") or std.mem.eql(u8, mode, "restore-idle") or std.mem.eql(u8, mode, "restore-no-key") or std.mem.eql(u8, mode, "restore-failure");
    // All child environment bytes are prepared before fork; missing-key case
    // terminates the env array before the fixture key, never inheriting HOME.
    const timezone = init.environ_map.get("THIN_APP_TEST_TZ") orelse "UTC0";
    try check(std.mem.eql(u8, timezone, "UTC0") or std.mem.eql(u8, timezone, "UTC-8"));
    const timezone_env = try a.dupeSentinel(u8, try std.fmt.allocPrint(a, "TZ={s}", .{timezone}), 0);
    const env = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", home_env, "LANG=C.UTF-8", "TERM=xterm-256color", timezone_env, if (std.mem.eql(u8, mode, "resume-login") or std.mem.eql(u8, mode, "restore-no-key") or (restore_error != null and std.mem.eql(u8, restore_error.?, "ApiKeyNotFound"))) null else "THIN_FIXTURE_KEY=fixture-secret-never-log" };

    const interactive_argv = [_:null]?[*:0]const u8{ bin, "--no-model-auto-refresh" };
    const print_argv = [_:null]?[*:0]const u8{ bin, "--print", "large-output" };
    const no_log_argv = [_:null]?[*:0]const u8{ bin, "--no-log", "--no-model-auto-refresh" };
    const restore_id = try a.dupeSentinel(u8, if (restore_mode or full_resume) try required(init, "THIN_APP_TEST_RESTORE_ID") else "", 0);
    const restore_argv = [_:null]?[*:0]const u8{ bin, "--restore-selection", restore_id, "--no-log" };
    const resume_argv = [_:null]?[*:0]const u8{ bin, "--resume", restore_id };
    const resume_no_log_argv = [_:null]?[*:0]const u8{ bin, "--resume", restore_id, "--no-log" };
    // output 模式直接执行 --print 大输出；其余模式启动交互式界面。
    const argv: [*:null]const ?[*:0]const u8 = if (full_resume) (if (std.mem.eql(u8, mode, "resume-readonly")) &resume_no_log_argv else &resume_argv) else if (restore_mode) &restore_argv else if (std.mem.eql(u8, mode, "output")) &print_argv else if (std.mem.eql(u8, mode, "exit-no-log") or (std.mem.startsWith(u8, mode, "settings-") and !std.mem.eql(u8, mode, "settings-image-model")) or std.mem.startsWith(u8, mode, "tool-preview-") or std.mem.startsWith(u8, mode, "test-queued-")) &no_log_argv else &interactive_argv;

    var master: c_int = undefined;
    var slave: c_int = undefined;

    var size = std.mem.zeroes(c.winsize);
    size.col = if (std.mem.startsWith(u8, mode, "settings-command-") and !std.mem.eql(u8, mode, "settings-command-stable")) 160 else 80;
    size.row = 24;

    // 创建 PTY 对，初始窗口尺寸为 80x24。
    try check(openpty(&master, &slave, null, null, &size) == 0);

    // handed_off 为 false 时由 errdefer 关闭 fd；一旦交给 Driver，所有权转移，由 Driver.deinit 负责。
    var handed_off = false;
    errdefer if (!handed_off) {
        _ = c.close(master);
        _ = c.close(slave);
    };

    var original: abi.Termios = undefined;
    try check(abi.tcgetattr(slave, &original) == 0);
    const flags = c.fcntl(slave, 3);

    // F_SETFL (4) 设置 O_NONBLOCK (0x800)，使 master 读取不会阻塞驱动循环。
    try check(c.fcntl(master, 4, @as(c_int, 0x800)) == 0);

    // Seed pre-existing terminal OUTPUT through the owned slave, never master
    // input. --print backpressure must wait for genuine application stdout.
    if (!std.mem.eql(u8, mode, "output")) {
        const seed = regular.prior ++ "\r\n";
        try check(c.write(slave, seed.ptr, seed.len) == seed.len);
    }

    // fork 之后子进程只能调用 async-signal-safe 的 libc 函数。
    const pid = fork();
    try check(pid >= 0);
    if (pid == 0) {
        // Async-signal-safe libc ONLY; all strings/argv/env prepared before fork.
        _ = c.close(master);
        // 创建新会话，使 slave 能成为子进程的控制终端。
        if (setsid() < 0) _exit(120);
        // TIOCSCTTY (0x540e)：把 slave 设为控制终端，使信号（如 Ctrl-C）能正确投递。
        if (c.ioctl(slave, @as(c_int, 0x540e), @as(c_int, 0)) < 0) _exit(121);
        // 将 slave 复制到 stdin/stdout/stderr。
        if (dup2(slave, 0) < 0 or dup2(slave, 1) < 0 or dup2(slave, 2) < 0) _exit(122);
        if (slave > 2) _ = c.close(slave);
        if (chdir(project) != 0) _exit(123);
        // execve 成功不会返回；返回则说明失败，以 124 退出，由父进程的 waitText/finish 发现。
        _ = execve(bin, argv, &env);
        _exit(124);
    }

    // 父进程安装 SIGTERM 与 SIGINT 处理器，使驱动在收到外部中断时能中止等待并清理子进程。
    _ = signal(15, onSignal);
    _ = signal(2, onSignal);

    // 将 fd 所有权交给 Driver，并用 defer 保证任何退出路径都会清理子进程与 fd。
    var d = Driver{ .master = master, .slave = slave, .pid = pid, .original = original, .flags = flags };
    handed_off = true;
    defer d.deinit();

    if (std.mem.eql(u8, mode, "output")) {
        // A slow output consumer must not trap the installed signal handler.
        // Wait for first output without reading, then leave this owned PTY full.
        var readable = [_]c.pollfd{.{ .fd = master, .events = 1, .revents = 0 }};
        try check(c.poll(&readable, 1, 10000) > 0);

        // 短暂停顿，确保子进程已因 PTY 缓冲区写满而阻塞在 write 上。
        var pause = [_]c.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
        _ = c.poll(&pause, 1, 150);

        // 在子进程阻塞写入时发送 SIGINT，验证取消路径不会被未读取的输出卡住。
        try check(kill(pid, 2) == 0);
        const until = now() + 2000;
        // 循环非阻塞回收，最长等待 2 秒；超时则报告取消超时。
        while (d.owned and now() < until) {
            const result = waitpid(pid, &d.status, 1);
            if (result == pid) d.owned = false;
            if (result < 0 and c._errno().* != 4) return error.WaitFailed;
            if (d.owned) _ = c.poll(&pause, 1, 5);
        }
        if (d.owned) return error.OutputCancellationTimeout;

        // 期望退出码 130（128 + SIGINT）。
        try d.finish(130);
        return;
    }

    // Startup refusals precede raw mode and the first frame. Check their exit
    // directly; waiting for a composer would mistake correct refusal for EOF.
    if (restore_error) |expected| {
        try d.finish(1);
        const message = try std.fmt.allocPrint(a, "thin: {s}", .{expected});
        try check(std.mem.indexOf(u8, d.output[0..d.used], message) != null);
        try check(std.mem.indexOfScalar(u8, d.output[0..d.used], 0x1b) == null);
        return;
    }
    // A complete composer frame shows the cursor; no statistics/status footer.
    try d.waitText(0, "\x1b[?25h");
    try check(std.mem.indexOf(u8, d.output[0..d.used], @import("../app/version.zig").text) != null);
    try check(std.mem.indexOf(u8, d.output[0..d.used], project) != null);
    try check(std.mem.indexOf(u8, d.output[0..d.used], "Directory:") == null);
    try check(std.mem.indexOf(u8, d.output[0..d.used], "Time:") == null);
    try check(std.mem.indexOf(u8, d.output[0..d.used], if (std.mem.eql(u8, timezone, "UTC-8")) " +0800" else " +0000") != null);
    try check(std.mem.indexOf(u8, d.output[0..d.used], "Zig ") == null);
    if (std.mem.startsWith(u8, mode, "test-queued-")) {
        try queuedScenario(&d, init, mode, project);
        return;
    }
    if (std.mem.eql(u8, mode, "auth-missing") or std.mem.eql(u8, mode, "auth-empty")) {
        // A generated disk default is not an activated selection. Do not enter
        // a key or submit a prompt: no public endpoint may be contacted.
        try d.waitText(0, "/login");
        const pending = try d.screen();
        try check(pending.visible("/model"));
        try check(!pending.visible("deepseek-flash") and !pending.visible("?%"));
        try check(std.mem.startsWith(u8, &pending.grid[pending.row], "> "));
        var start = d.used;
        try d.send("/model\r");
        try d.waitFrame(start, "No logged-in providers");
        const no_providers = try d.screen();
        try check(no_providers.visible("Search> ") and !no_providers.visible("Provider> ") and !no_providers.visible("deepseek-flash"));
        start = d.used;
        try d.send("\x1b");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/login\r");
        try d.waitFrame(start, "Provider> ");
        const login = try d.screen();
        try check(login.visible("DeepSeek") and login.visible("OpenCode Zen") and login.visible("OpenCode Go"));
        start = d.used;
        try d.send("\x1b");
        try d.waitIdle(start);
    } else if (std.mem.eql(u8, mode, "manual-compact")) {
        var start = d.used;
        try d.send("manual-first\r");
        try d.waitText(start, "manual-first-answer");
        try d.waitIdle(start);
        start = d.used;
        try d.send("manual-second\r");
        try d.waitText(start, "manual-second-answer");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/co");
        try d.waitFrame(start, "/compact  Compact conversation");
        start = d.used;
        try d.send("\r");
        try d.waitText(start, "Context compacted:");
        try d.waitIdle(start);
        const compacted = try d.screen();
        try check(compacted.visible("Context compacted:"));
        try check(!compacted.visible("Unknown command"));
    } else if (std.mem.eql(u8, mode, "read-error")) {
        const start = d.used;
        try d.send("read-missing\r");
        try d.waitFrame(start, "[error] FileNotFound: file not found");
        try d.waitText(start, "read-error-answer");
        try d.waitIdle(start);
    } else if (std.mem.eql(u8, mode, "menu-navigation")) {
        // Offline only: no message or credential is submitted. Every navigation
        // waits for a complete owned frame before a subsequent confirmation.
        var start = d.used;
        try d.send("/");
        try d.waitFrame(start, "/login");
        try d.checkMenu("/model", ") > /");
        start = d.used;
        const commands = try d.screen();
        // The loopback fixture explicitly opts out; the default-on marker must
        // not be inferred merely from the presence of a context percentage.
        try check(std.mem.indexOf(u8, &commands.grid[commands.row], " L ") == null);
        try check(commands.visible("/model [exact-id|--refresh]  Select model"));
        // Inspect logical terminal cells, not raw SGR/padding substrings.
        var description_column: ?usize = null;
        var descriptions: usize = 0;
        for ([_][]const u8{ "Select model", "Configure provider", "Compact conversation", "Global settings" }) |description| {
            var found = false;
            for (commands.grid) |line| {
                if (std.mem.indexOf(u8, &line, description)) |column| {
                    if (description_column) |expected| try check(column == expected) else description_column = column;
                    try check(!found);
                    found = true;
                }
            }
            try check(found);
            descriptions += 1;
        }
        try check(descriptions == 4);
        try d.send("\x1b[B"); // /model -> /login; /compact is the third root row.
        try d.waitFrame(start, "");
        start = d.used;
        try d.send("\t");
        try d.waitFrame(start, "");
        const login_completed = try d.screen();
        try check(std.mem.indexOf(u8, &login_completed.grid[login_completed.row], ") > /login") != null);
        try check(!login_completed.visible("Provider> ") and !login_completed.visible("API key> "));
        start = d.used;
        try d.send("\r");
        try d.waitFrame(start, "Provider> ");
        try d.checkMenu("DeepSeek", "Provider> ");
        const providers = try d.screen();
        try check(providers.row > 0);
        try check(!providers.visible("Configure provider"));
        start = d.used;
        try d.send("\x1b[D"); // Provider -> root, not a cursor movement.
        try d.waitFrame(start, "");
        const root = try d.screen();
        try check(root.visible("/model") and root.visible("/login") and !root.visible("Provider> "));
        start = d.used;
        try d.send("\x15");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/");
        try d.waitFrame(start, "/login");
        start = d.used;
        try d.send("\x1b[B");
        try d.waitFrame(start, "");
        start = d.used;
        try d.send("\x1b[A"); // Up from /login returns to /model.
        try d.waitFrame(start, "");
        start = d.used;
        try d.send("\t");
        try d.waitFrame(start, "");
        const model_completed = try d.screen();
        try check(std.mem.indexOf(u8, &model_completed.grid[model_completed.row], ") > /model") != null);
        try check(!model_completed.visible("Search> "));
        start = d.used;
        try d.send("\r");
        try d.waitFrame(start, "Search> ");
        const model_list = try d.screen();
        try check(!model_list.visible("Provider> ") and !model_list.visible("deepseek-flash") and !model_list.visible("claude-haiku"));
        try d.checkMenu("fixture-model  (", "Search> ");
        const models = try d.screen();
        try check(!models.visible("Commands") and !models.visible("Configure provider"));
        start = d.used;
        try d.send("\x1b[D"); // Model -> root (no provider stage).
        try d.waitFrame(start, "");
        const model_parent = try d.screen();
        try check(model_parent.visible("/model") and model_parent.visible("/login") and !model_parent.visible("Search> "));
        start = d.used;
        try d.send("\x15");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/co");
        try d.waitFrame(start, "Compact conversation");
        start = d.used;
        try d.send("\t");
        try d.waitFrame(start, "");
        const compact_completed = try d.screen();
        try check(std.mem.indexOf(u8, &compact_completed.grid[compact_completed.row], ") > /compact") != null);
        try check(!compact_completed.visible("Context compacted:"));
        start = d.used;
        try d.send("\x15");
        try d.waitIdle(start);
        try d.openAuth();
        start = d.used;
        try d.send("\x1b[200~fixture-secret-never-log\x1b[201~");
        try d.waitFrame(start, "*");
        start = d.used;
        try d.send("\x1b"); // Wipe the secret AND release paste quarantine.
        try d.waitIdle(start);
        try d.openAuth(); // Would fail if quarantine still swallowed /login.
        const empty_secret = try d.screen();
        try check(empty_secret.visible("API key> ") and !empty_secret.visible("***"));
        start = d.used;
        try d.send("\x1b");
        try d.waitIdle(start);
        start = d.used;
        try d.send("ordinary-edit");
        try d.waitFrame(start, "ordinary-edit");
        start = d.used;
        try d.send("\x15");
        try d.waitIdle(start);
        const cleared = try d.screen();
        try check(!cleared.visible("ordinary-edit"));
        start = d.used;
        try d.send("/model --refresh\r");
        try d.waitFrame(start, "No official provider configured");
        // This fixture uses a custom loopback endpoint: refresh must not send
        // its credential to any official service or submit a model request.
        try check(std.mem.indexOf(u8, d.output[0..d.used], "Saved locally; send a message to connect") == null);
    } else if (std.mem.eql(u8, mode, "auth-go")) {
        var login_stage: usize = 1;
        errdefer std.debug.print("error: GoLoginStage{d}\n", .{login_stage});
        var start = d.used;
        try d.send("/model ");
        try d.waitFrame(start, "/model ");
        const command = try d.screen();
        try check(command.visible("/model ") and !command.visible("arguments hidden"));
        login_stage = 2;
        start = d.used;
        try d.send("\x15");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/login\r");
        try d.waitFrame(start, "Provider> ");
        start = d.used;
        try d.send("\x1b[A"); // Wrap first row to Go; active sessions omit Current endpoint.
        try d.waitFrame(start, ">   OpenCode Go");
        login_stage = 3;
        start = d.used;
        try d.send("\r");
        try d.waitFrame(start, "API key> ");
        login_stage = 4;
        start = d.used;
        try d.send("\x1b[200~fixture-secret-never-log\x1b[201~");
        try d.waitFrame(start, "***");
        login_stage = 5;
        start = d.used;
        try d.send("\r");
        try d.waitFrame(start, "Key saved locally");
        const saved = try d.screen();
        try check(!saved.visible("API key>") and !saved.visible("***") and !saved.visible("Provider> "));
        // No Escape/Ctrl+U unlock step: fresh text must immediately be editable.
        login_stage = 6;
        start = d.used;
        try d.send("ordinary-after-login");
        try d.waitFrame(start, "ordinary-after-login");
        login_stage = 7;
        start = d.used;
        try d.send("\x15");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/model\r");
        try d.waitFrame(start, "Search> ");
        start = d.used;
        try d.send("opencode-go/claude-haiku");
        try d.waitFrame(start, "opencode-go/claude-haiku-5-5");
        login_stage = 8;
        start = d.used;
        try d.send("\x15");
        try d.waitFrame(start, "Search> ");
        start = d.used;
        try d.send("opencode-go/kimi-k3");
        try d.waitFrame(start, "opencode-go/kimi-k3  (");
        login_stage = 9;
        start = d.used;
        try d.send("\x1b");
        try d.waitIdle(start);
    } else if (std.mem.eql(u8, mode, "resume-create")) {
        const start = d.used;
        try d.send("resume-first-turn remember-resume-marker\r");
        try d.waitText(start, "resume-first-answer");
        try d.waitIdle(start);
    } else if (full_resume) {
        try d.waitFrame(0, if (std.mem.eql(u8, mode, "resume-login")) "Not logged in" else "prior tools are NOT rerun");
        try check(std.mem.indexOf(u8, d.output[0..d.used], "resume-first-answer") != null);
        try check(std.mem.indexOf(u8, d.output[0..d.used], "PRIVATE-RESUME-REASONING") == null);
        try d.quiet(150); // No startup model request or historical execution.
        if (std.mem.eql(u8, mode, "resume-login")) {
            try d.waitFrame(0, "Not logged in");
            try d.openAuth();
            const login_start = d.used;
            try d.send("fixture-secret-never-log\r");
            // The restored-owner notice may follow this in the bounded hint
            // row; check its visible save prefix, then exact continuation below.
            try d.waitFrame(login_start, "Saved locally");
            try check(std.mem.indexOf(u8, d.output[0..d.used], "resume-first-answer") != null);
        }
        if (!std.mem.eql(u8, mode, "resume-idle")) {
            const start = d.used;
            try d.send("resume-next-turn\r");
            try d.waitText(start, "resume-next-answer");
            try d.waitIdle(start);
        }
    } else if (std.mem.eql(u8, mode, "restore-idle") or std.mem.eql(u8, mode, "restore-no-key")) {
        try d.waitFrame(0, if (std.mem.eql(u8, mode, "restore-no-key")) "Not logged in" else "history not restored");
        try check(std.mem.indexOf(u8, d.output[0..d.used], "OLD-HISTORY-MUST-NOT-APPEAR") == null);
        try d.quiet(150);
    } else if (std.mem.eql(u8, mode, "restore-selection")) {
        try d.waitFrame(0, "history not restored");
        try check(std.mem.indexOf(u8, d.output[0..d.used], "fixture-restored") != null);
        try check(std.mem.indexOf(u8, d.output[0..d.used], "OLD-HISTORY-MUST-NOT-APPEAR") == null);
        const start = d.used;
        try d.send("restore-new-turn\r");
        try d.waitText(start, "restore-fresh-answer");
        try d.waitIdle(start);
    } else if (std.mem.eql(u8, mode, "exit-no-submit") or std.mem.eql(u8, mode, "exit-unconfigured") or std.mem.eql(u8, mode, "exit-batched")) {
        try d.quiet(100);
    } else if (std.mem.eql(u8, mode, "exit-secret")) {
        try d.openAuth();
        try d.send("fixture-secret-never-log");
        try d.quiet(100);
    } else if (std.mem.eql(u8, mode, "exit-no-log")) {
        const start = d.used;
        try d.send("fixture-task\r");
        try d.waitText(start, "fixture-answer");
        try d.waitIdle(start);
    } else if (std.mem.eql(u8, mode, "exit-busy") or std.mem.eql(u8, mode, "exit-busy-tool")) {
        const start = d.used;
        try d.send("exit-busy-task\r");
        if (std.mem.eql(u8, mode, "exit-busy-tool")) {
            try d.waitRunningFrame(start, "sleep 30");
        } else {
            // A busy composer alone is not evidence that Runtime accepted its
            // user or sent HTTP. Test an IN-FLIGHT request, not pre-start cancel.
            try queuedFile(&d, a, project, "exit-busy-arrived");
            try d.waitBusy(start);
        }
        // Ctrl+D at the shared tail below cancels and joins before restoration.
    } else if (std.mem.eql(u8, mode, "auth-activate")) {
        // 待激活配置指向本地 fixture。/login 使用独立的掩码输入，取消不能保存或污染聊天输入。
        try d.waitText(0, "/login");
        var start = d.used;
        try d.openAuth();
        try d.quiet(150);
        start = d.used;
        try d.send("\x1b[200~fixture-secret-never-log\x1b[201~");
        try d.quiet(150);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Saved locally; send a message to connect") == null);
        try d.send("\x03");
        try d.quiet(150);
        try check(d.owned);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Saved locally; send a message to connect") == null);

        // 粘贴退出后保持保护，按屏幕提示显式 Ctrl+U，避免剩余密钥字节进入普通输入。
        try d.send("\x15");
        try d.quiet(150);

        // 再次打开，粘贴本身不能保存；只有显式 Enter 才能提交，并在同一进程激活配置。
        start = d.used;
        try d.openAuth();
        try d.quiet(150);
        start = d.used;
        try d.send("\x1b[200~fixture-secret-never-log\x1b[201~");
        try d.quiet(150);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Saved locally; send a message to connect") == null);
        try d.send("\r");
        try d.waitText(start, "Saved locally; send a message to connect");
        try d.quiet(150);
        try d.send("\x15");
        try d.quiet(150);

        start = d.used;
        try d.send("fixture-task\r");
        try d.waitText(start, "fixture-answer");
        try d.waitIdle(start);
    } else if (std.mem.eql(u8, mode, "log-idle")) {
        // 已配置但尚未提交：Node 检查退出后仍没有日志目录。
        try d.quiet(150);
    } else if (std.mem.eql(u8, mode, "date")) {
        const start = d.used;
        try d.send("获取时间\r");
        // 默认直接运行真实 date，不发送 y/n/t；无响应会由驱动截止时间判失败。
        try d.waitText(start, "date-completed");
        try d.waitIdle(start);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Approval #") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Completed") == null);
    } else if (std.mem.eql(u8, mode, "regular-two")) {
        // Same owned PTY, two loopback-only turns. Force the first reply into
        // scrollback; repeated input-tail redraws must not append it again.
        for ([_][]const u8{ "regular-first", "regular-second" }, 0..) |prompt, turn| {
            const start = d.used;
            try d.send(prompt);
            try d.send("\r");
            try d.waitText(start, if (turn == 0) "regular-answer-one" else "regular-answer-two");
            try d.waitIdle(start);
            try d.quiet(150);
            try d.send("tail-refresh");
            try d.quiet(150);
            try d.send("\x15");
            try d.quiet(150);
            const current = try d.screen();
            try check(current.count("regular-answer-one") == 1);
            if (turn == 1) try check(current.count("regular-answer-two") == 1);
        }
    } else if (std.mem.eql(u8, mode, "stream-native-history")) {
        try d.waitIdle(0);
        const start = d.used;
        try d.send("native-scroll-task\r");
        try d.waitFrame(start, "native-row-039");
        var stage = try d.screen();
        if (stage.history_len < 8) return error.NativeHistoryMissing;
        const top = stage.history_len - 8;
        const old_history = stage.history_len;
        var pinned: [24][80]u8 = undefined;
        for (&pinned, 0..) |*line, index| {
            const position = top + index;
            @memcpy(line, if (position < stage.history_len) &stage.history[position] else &stage.grid[position - stage.history_len]);
        }
        // No mouse events are sent. Observe the same absolute native viewport
        // while streaming continues beneath it, as a scrolled terminal would.
        try d.waitFrame(start, "native-row-069");
        stage = try d.screen();
        if (stage.history_len <= old_history) return error.NativeHistoryDidNotGrow;
        for (&pinned, 0..) |*line, index| {
            const position = top + index;
            const actual = if (position < stage.history_len) &stage.history[position] else &stage.grid[position - stage.history_len];
            if (!std.mem.eql(u8, line, actual)) return error.NativeHistoryChanged;
        }
        try d.waitIdle(start);
        stage = try d.screen();
        try check(stage.count("native-row-") == 70);
        try check(stage.count("native-row-000") == 1 and stage.count("native-row-069") == 1);
        try check(stage.count("Response revised") == 0);
        try check(stage.count("native-scroll-task") == 1);
    } else if (std.mem.eql(u8, mode, "stream-markdown")) {
        try d.waitIdle(0);
        const initial = try d.screen();
        try check(std.mem.indexOf(u8, &initial.grid[23], "(fixture-model 0.0%) >") != null);
        const start = d.used;
        try d.send("stream-task\r");
        try d.waitText(start, "reasoning-stage-one");
        try d.quiet(100);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Completed") == null);
        var stage = try d.screen();
        // Check the actual streamed reasoning on the logical terminal, not
        // only Record.layout: Markdown punctuation must remain literal.
        if (!stage.visible("# **thinking-old-two**") or !stage.visible("- `thinking-old-three`")) return error.ThinkingMarkupNotLiteral;
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;103m# **thinking-old-two**") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;103m- `thinking-old-three`") != null);
        try check(stage.visible("reasoning-stage-one") and stage.row == 23);
        try Driver.checkGap(&stage, "stream-task", "thinking-old-two");
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Thinking") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "thin |") == null);
        try check(!stage.visible("thinking-old-one"));
        try check(stage.visible("thinking-old-two") and stage.visible("thinking-old-three"));
        try d.waitText(start, "reasoning-stage-two");
        try d.quiet(100);
        stage = try d.screen();
        try check(stage.visible("thinking-new-five") and stage.visible("thinking-new-six") and stage.visible("reasoning-stage-two"));
        try check(!stage.visible("reasoning-stage-one") and !stage.visible("thinking-old-two"));
        try Driver.checkGap(&stage, "stream-task", "thinking-new-five");
        try check(std.mem.indexOf(u8, &stage.grid[23], "(fixture-model ") != null and std.mem.indexOf(u8, &stage.grid[23], "%) ~") != null and stage.row == 23);
        for (stage.grid[22]) |byte| try check(byte == ' ');
        try check(!stage.visible("TPS:") and !stage.visible("tokens in:"));
        try check(std.mem.indexOf(u8, &stage.grid[23], "(fixture-model 0.0%) ~") != null);
        try d.waitText(start, "stream-stage-one");
        try d.quiet(100);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Completed") == null);
        stage = try d.screen();
        try check(stage.visible("Orange heading") and stage.visible("stream-stage-one") and stage.row == 23);
        try Driver.checkGap(&stage, "stream-task", "Orange heading");
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Streaming") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "History preview") == null);
        try check(!stage.visible("reasoning-stage-two") and !stage.visible("Thinking"));
        try check(!stage.visible("Enter send") and !stage.visible("Ctrl+J newline"));
        try check(std.mem.indexOf(u8, d.output[start..d.used], "[user]") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "[assistant") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;208m") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[48;2;52;36;24m") != null);
        // Do not satisfy completion with the old idle composer emitted before
        // this request. Wait for an acknowledged frame after the final delta.
        const final_start = d.used;
        try d.waitText(final_start, "stream-final-answer");
        try d.waitIdle(final_start);
        try d.quiet(100);
        stage = try d.screen();
        try check(stage.count("reasoning-stage-one") == 0 and stage.count("reasoning-stage-two") == 0);
        try check(stage.count("thinking-new-five") == 0 and stage.count("stream-final-answer") == 1);
        try Driver.checkGap(&stage, "stream-task", "Orange heading");
        try check(!stage.visible("TPS:") and !stage.visible("tokens in:") and !stage.visible("Completed"));
        try check(std.mem.indexOf(u8, &stage.grid[23], "(fixture-model ") != null and std.mem.indexOf(u8, &stage.grid[23], "%) >") != null);
        try check(stage.count("Final answer") == 0 and !stage.visible("ctx ~"));
        // Loopback provider reported 12 input + 90 output = 102 total: 0.3%.
        // Cached9/reasoning30 already belong to those counts, not extra context.
        try check(std.mem.indexOf(u8, &stage.grid[23], "(fixture-model 0.3%) >") != null);
        // Real streamed Markdown uses independent semantic colors and a boxed
        // grid with a second body row, not just its old header-only rule.
        const markdown_output = d.output[start..d.used];
        for ([_][]const u8{ "\x1b[1m\x1b[38;5;220m", "\x1b[38;5;141m", "\x1b[39m\x1b[2m", "\x1b[1m", "\x1b[38;5;77m", "┌", "├", "┼", "└", "second-row", "exit_code=124", "exit_code=0" }, 0..) |part, part_index| {
            const found = std.mem.indexOf(u8, markdown_output, part) != null;
            if (!found) std.debug.print("Markdown assertion index: {d}\n", .{part_index}); // Safe index, never captured bytes.
            try check(found);
        }
        // The independent model-name flow may legitimately contain orange.
        try check(std.mem.indexOf(u8, markdown_output, "\x1b[38;5;215m\x1b[1mstream-stage-one") == null);
        try check(std.mem.indexOf(u8, markdown_output, "\x1b[38;5;141minline-marker\x1b[0m") != null);
        try check(std.mem.indexOf(u8, markdown_output, "\x1b[38;2;") == null);
        // Code remains foreground-only and unpadded; user background is separate.
        for ([_][]const u8{ "exit_code=124", "exit_code=0" }) |code| {
            const expected = try std.fmt.allocPrint(a, "\x1b[38;5;77m{s}\x1b[0m", .{code});
            defer a.free(expected);
            try check(std.mem.indexOf(u8, markdown_output, expected) != null);
        }
        try check(std.mem.indexOf(u8, markdown_output, "(\x1b[38;5;75mfixture-model\x1b[0m \x1b[38;5;114m0.3%\x1b[0m) > ") != null); // High model, static green occupancy.
        try check(std.mem.indexOf(u8, markdown_output, "\x1b[38;5;75m>\x1b[0m") == null);
        for (stage.grid[22]) |byte| try check(byte == ' ');
        try check(stage.row == 23);
    } else if (std.mem.eql(u8, mode, "architecture-table")) {
        const start = d.used;
        try d.send("architecture-table-task\r");
        try d.waitText(start, "architecture-table-final-answer");
        try d.waitIdle(start);
        const final = try d.screen();
        try check(final.count("architecture-table-final-answer") == 1 and final.row == 23);
        const raw = d.output[start..d.used];
        for ([_][]const u8{ "┌", "┬", "┼", "└", "┴", "app/", "core/", "llm/", "platform/", "util/" }) |marker| try check(std.mem.indexOf(u8, raw, marker) != null);
        try check(std.mem.indexOf(u8, raw, "|---|---|") == null);
        try check(std.mem.indexOf(u8, raw, "Markdown complexity limit") == null);
        try check(std.mem.indexOf(u8, raw, "Streaming") == null);
    } else if (std.mem.eql(u8, mode, "tool-icons")) {
        const start = d.used;
        // Startup already shows configured high on idle text, not the marker.
        try check(std.mem.indexOf(u8, d.output[0..start], "(\x1b[38;5;75mfixture-model\x1b[0m \x1b[38;5;114m0.0%\x1b[0m) > ") != null);
        try check(std.mem.indexOf(u8, d.output[0..start], "%\x1b[0m) > ") != null);
        try check(std.mem.indexOf(u8, d.output[0..start], "\x1b[38;5;75m>\x1b[0m") == null);
        try d.send("tool-icon-task\r");
        try d.waitRunningFrame(start, "sleep 1; cat r.json");
        const animation_start = d.used;
        try d.quiet(120);
        const first = try d.screen();
        try d.quiet(240);
        const second = try d.screen();
        try check(first.visible("~ sleep 1; cat r.json") and second.visible("~ sleep 1; cat r.json"));
        try Driver.checkGap(&first, "tool-icon-task", "~ sleep 1; cat r.json");
        try Driver.checkGap(&second, "tool-icon-task", "~ sleep 1; cat r.json");
        // The ASCII VT fixture maps non-ASCII glyphs to '~'; inspect only these
        // renderer-owned braille symbols, not a general Unicode-width claim.
        var frames: usize = 0;
        for ([_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }) |icon| {
            if (std.mem.indexOf(u8, d.output[animation_start..d.used], icon) != null) frames += 1;
        }
        try check(frames >= 2);
        var pulses: usize = 0;
        for ([_][]const u8{ "\x1b[38;5;173m", "\x1b[38;5;208m", "\x1b[38;5;214m", "\x1b[38;5;220m", "\x1b[38;5;223m" }) |color| {
            var present = false;
            for ([_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }) |icon| {
                var pattern: [96]u8 = undefined;
                const effect = try std.fmt.bufPrint(&pattern, "{s}{s}\x1b[38;5;245m sleep 1; cat r.json", .{ color, icon });
                present = present or std.mem.indexOf(u8, d.output[animation_start..d.used], effect) != null;
            }
            if (present) pulses += 1;
        }
        try check(pulses >= 2); // Distinct prefix shades, not repeated glyph/text.
        try check(std.mem.indexOf(u8, d.output[start..d.used], ">_") == null);
        try check(first.row == 23 and second.row == 23);
        try check(std.mem.indexOf(u8, &first.grid[23], "(fixture-model ") != null and std.mem.indexOf(u8, &first.grid[23], "%) ~") != null);
        for (first.grid[22]) |byte| try check(byte == ' ');
        try d.waitRunningFrame(start, "sleep 0.6; printf ok");
        const next_pending = try d.screen();
        var completed_row: ?usize = null;
        var next_row: ?usize = null;
        for (next_pending.grid, 0..) |line, row| {
            if (std.mem.indexOf(u8, &line, "> sleep 1; cat r.json") != null) completed_row = row;
            if (std.mem.indexOf(u8, &line, "~ sleep 0.6; printf ok") != null) next_row = row;
        }
        try check(completed_row != null and next_row != null);
        try check(next_row.? == completed_row.? + 1 and next_pending.row == 23);
        try d.waitText(start, "tool-icon-final-answer");
        try d.waitIdle(start);
        try d.quiet(100);
        const final = try d.screen();
        try check(final.count("tool-icon-final-answer") == 1);
        var command_rows: [3]?usize = @splat(null);
        const markers = [_][]const u8{ "> sleep 1; cat r.json", "> sleep 0.6; printf ok", "> false; #" };
        for (final.grid, 0..) |line, row| {
            var calls_on_row: usize = 0;
            for (markers, 0..) |marker, index| if (std.mem.indexOf(u8, &line, marker) != null) {
                command_rows[index] = row;
                calls_on_row += 1;
            };
            try check(calls_on_row <= 1);
        }
        try check(command_rows[0] != null and command_rows[1] != null and command_rows[2] != null);
        try check(command_rows[1].? == command_rows[0].? + 1 and command_rows[2].? == command_rows[1].? + 1);
        try check(final.count(markers[0]) == 1 and final.count(markers[1]) == 1 and final.count(markers[2]) == 1);
        try check(final.row == 23);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[0m\x1b[38;5;114m>\x1b[38;5;245m sleep 0.6; printf ok") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[0m\x1b[38;5;203m>\x1b[38;5;203m false; #") != null); // Failure prefix; summary still clips at80% in its existing failure color.
        try check(std.mem.indexOf(u8, d.output[start..d.used], "...\x1b[0m") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "·") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "bash #") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "tool-json-hidden-marker") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Running bash") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Enter send") == null);
    } else if (std.mem.eql(u8, mode, "memory-summary")) {
        const start = d.used;
        try d.send("memory-summary-task\r");
        try d.waitText(start, "memory-summary-final-answer");
        try d.waitIdle(start);
        const final = try d.screen();
        for ([_][]const u8{ "m write caption-note", "m read caption-note", "m list core/index", "m delete caption-note" }) |caption| {
            try check(final.count(caption) == 1);
        }
        try check(std.mem.indexOf(u8, d.output[start..d.used], "memory-summary-hidden-body") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "expected_version") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[0m\x1b[38;5;114mm\x1b[38;5;245m read caption-note") != null);
        try check(final.count("memory-summary-final-answer") == 1 and final.row == 23);
    } else if (std.mem.eql(u8, mode, "file-stats")) {
        const start = d.used;
        try d.send("file-stats-task\r");
        try d.waitText(start, "file-stats-final-answer");
        try d.waitIdle(start);
        const final = try d.screen();
        var previous: ?usize = null;
        for ([_][]const u8{ "w stats.txt  ~0 +5 -0 lines", "w stats.txt  ~1 +1 -1 lines", "r stats.txt  5 lines", "r stats.txt  2 lines [partial]", "w stats.txt  ~0 +0 -5 lines", "w stats.txt [error]" }) |caption| {
            try check(final.count(caption) == 1);
            var found: ?usize = null;
            for (final.grid, 0..) |line, row| if (std.mem.indexOf(u8, &line, caption) != null) {
                found = row;
            };
            try check(found != null);
            if (previous) |row| try check(found.? == row + 1);
            previous = found;
        }
        try check(final.count("Final answer") == 0 and final.count("file-stats-final-answer") == 1);
        try Driver.checkGap(&final, "file-stats-task", "w stats.txt");
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[0m\x1b[38;5;114mw\x1b[38;5;245m stats.txt") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[0m\x1b[38;5;114mr\x1b[38;5;245m stats.txt") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[0m\x1b[38;5;203mw\x1b[38;5;203m stats.txt [error]") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;2m+1\x1b[38;5;245m") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;1m-1\x1b[38;5;245m") != null);
        for ([_][]const u8{ "read_file ", "write_file ", "memory read " }) |old_label| try check(std.mem.indexOf(u8, d.output[start..d.used], old_label) == null);
        var answer: ?usize = null;
        for (final.grid, 0..) |line, row| if (std.mem.indexOf(u8, &line, "file-stats-final-answer") != null) {
            answer = row;
        };
        try check(answer != null and answer.? == previous.? + 2);
        for (final.grid[answer.? - 1]) |byte| try check(byte == ' ');
        try check(std.mem.indexOf(u8, &final.grid[23], "(fixture-model ") != null and std.mem.indexOf(u8, &final.grid[23], "%) >") != null);
        try check(!final.visible("ctx ~"));
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\"written_bytes\"") == null);
    } else if (std.mem.startsWith(u8, mode, "tool-preview-")) {
        try toolPreview(&d, init, mode, project);
    } else if (std.mem.eql(u8, mode, "settings-values")) {
        try settingsValuesJourney(&d, init, project);
    } else if (std.mem.eql(u8, mode, "settings-image-model")) {
        try imageModel(&d, init, project);
    } else if (std.mem.startsWith(u8, mode, "settings-decision-model-")) {
        try decisionModel(&d, init, mode, project);
    } else if (std.mem.eql(u8, mode, "settings-approval-cancel")) {
        try approvalCancel(&d);
    } else if (std.mem.startsWith(u8, mode, "settings-command-")) {
        try localCommand(&d, mode);
    } else if (std.mem.startsWith(u8, mode, "settings-global")) {
        // Handle before the historical thinking-level settings-* dispatcher.
        // No prompt, model selection, refresh or inference is submitted here.
        try globalSettings(&d, mode);
    } else if (std.mem.startsWith(u8, mode, "settings-")) {
        // All settings processes are real owned PTYs with --no-log. Check an
        // acknowledged initial frame before typing; a missing preference is initialized.
        try d.waitIdle(0);
        if (std.mem.eql(u8, mode, "settings-initial")) try settingsColor(&d, 0, "off");
        if (std.mem.eql(u8, mode, "settings-cycle") or std.mem.eql(u8, mode, "settings-map")) {
            try settingsColor(&d, 0, "off");
            const levels: []const []const u8 = if (std.mem.eql(u8, mode, "settings-cycle")) &.{ "low", "high", "max", "off" } else &.{ "low", "high", "off" };
            for (levels) |level| {
                var start = d.used;
                try d.send("\x1b[Z");
                try d.waitIdle(start);
                try settingsColor(&d, start, level);
                start = d.used;
                try d.send("settings-task\r");
                try d.waitText(start, "settings-answer");
                try d.waitIdle(start);
            }
            if (std.mem.eql(u8, mode, "settings-cycle")) {
                // Leave max saved without another HTTP call.
                for ([_][]const u8{ "low", "high", "max" }) |level| {
                    const start = d.used;
                    try d.send("\x1b[Z");
                    try d.waitIdle(start);
                    try settingsColor(&d, start, level);
                }
            }
        } else if (std.mem.eql(u8, mode, "settings-pending-auth")) {
            try d.waitText(0, "/login");
            var start = d.used;
            try d.send("\x1b[Z");
            // Cycling a pending preference may leave the bare prompt pixels
            // unchanged. Require a new complete frame, not an unchanged footer.
            try d.waitFrame(start, "\x1b[?25l");
            const pending = try d.screen();
            try check(std.mem.startsWith(u8, &pending.grid[pending.row], "> ") and !pending.visible("fixture-model"));
            start = d.used;
            try d.openAuth();
            start = d.used;
            try d.send("fixture-secret-never-log\r");
            try d.waitText(start, "Saved locally; send a message to connect");
            try d.waitIdle(start);
            try settingsColor(&d, start, "low");
            start = d.used;
            try d.send("settings-task\r");
            try d.waitText(start, "settings-answer");
            try d.waitIdle(start);
        } else if (!std.mem.eql(u8, mode, "settings-initial")) {
            const blocked = std.mem.eql(u8, mode, "settings-blocked-low") or std.mem.eql(u8, mode, "settings-unknown-low");
            const clamped = std.mem.startsWith(u8, mode, "settings-clamp-");
            const level = if (blocked) "low" else if (clamped or std.mem.startsWith(u8, mode, "settings-probe-")) mode[15..] else return error.UnknownSettingsMode;
            try settingsColor(&d, 0, level);
            if (clamped) try d.waitText(0, "Saved thinking level adjusted");
            if (std.mem.eql(u8, mode, "settings-unknown-low")) try d.waitText(0, "Saved thinking level not applied");
            if (blocked) {
                const before = try d.screen();
                const start = d.used;
                try d.send("\x1b[Z");
                // Unknown/fixed capabilities keep the same idle composer. A
                // completed sparse frame may only replace its notice row; do
                // not require unchanged model/percentage pixels to be reprinted.
                try d.waitFrame(start, "\x1b[?25l");
                const after = try d.screen();
                try check(std.mem.eql(u8, &before.grid[23], &after.grid[23]) and after.row == 23);
                if (std.mem.indexOf(u8, d.output[start..d.used], "fixture-model") != null) {
                    try settingsColor(&d, start, level);
                } else {
                    // No new styled footer payload: the previously verified
                    // low color is retained, not silently replaced by another.
                    try settingsColor(&d, 0, level);
                }
            }
            const start = d.used;
            try d.send("settings-task\r");
            try d.waitText(start, "settings-answer");
            try d.waitIdle(start);
        }
        const final = try d.screen();
        try check(final.row == 23 and final.count(regular.prior) == 1);
    } else if (std.mem.eql(u8, mode, "model-select-empty")) {
        const start = d.used;
        try d.send("/model fixture-next\r");
        try d.waitFrame(start, "fixture-next");
        try d.waitIdle(start);
        const selected = try d.screen();
        try check(selected.visible("fixture-next") and !selected.visible("Model selection failed"));
    } else if (std.mem.eql(u8, mode, "model-select")) {
        var start = d.used;
        try d.send("selection-first\r");
        try d.waitBusy(start);
        // Neither the effort shortcut nor direct command may mutate a live
        // request. The server checks exact first/continuation wire options.
        try d.send("\x1b[Z/model rejected-busy\r");
        try d.waitText(start, "selection-answer-one");
        try d.waitIdle(start);
        // Busy special commands are rejected without destroying their draft.
        // The user explicitly clears it before opening a new local menu; it
        // must not silently become Steering or a second inference request.
        try queuedDraft(&d, a, "/model rejected-busy");
        start = d.used;
        try d.send("\x15/");
        try d.waitFrame(start, "/login");
        const commands = try d.screen();
        try check(commands.visible("/model") and commands.visible("/login"));
        try check(!commands.visible("Commands") and !commands.visible("Search> "));
        start = d.used;
        try d.send("\r");
        try d.waitFrame(start, "Search> ");
        start = d.used;
        try d.send("\x1b[B");
        try d.waitFrame(start, "Search> ");
        start = d.used;
        try d.send("\r");
        try d.waitIdle(start);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "fixture-next") != null);
        // No global override exists: the selected profile's configured low is
        // now the default, not an obsolete project preference. ACK-safe redraws
        // may emit changed cells only; inspect the resulting idle screen. The
        // exact medium wire after ONE shortcut below proves low was applied.
        const selected_next = try d.screen();
        try check(selected_next.visible("fixture-next") and selected_next.visible("?%"));
        try check(selected_next.row == 23 and !selected_next.visible("Search> "));
        start = d.used;
        try d.send("\x1b[Z"); // Selected profile low -> medium.
        // Observe the acknowledged confirmation, then its automatic expiry.
        // Intermediate levels may render if PTY input arrives in separate reads.
        try d.waitFrame(start, "(fixture-next medium) > ");
        try d.waitIdle(start);
        start = d.used;
        try d.send("selection-second\r");
        try d.waitText(start, "selection-answer-two");
        try d.waitIdle(start);
        start = d.used;
        try d.send("/model\r");
        try d.waitFrame(start, "Search> ");
        start = d.used;
        try d.send("\x1b"); // Owned ambiguity timeout for standalone Escape.
        try d.waitIdle(start);
        start = d.used;
        try d.send("/model fixture-custom\r");
        try d.waitIdle(start);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "fixture-custom") != null);
        start = d.used;
        try d.send("\x1b[Z");
        try d.waitIdle(start);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "(\x1b[38;5;75mfixture-custom\x1b[0m \x1b[38;5;75m") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;75m>\x1b[0m") == null);
        start = d.used;
        try d.send("selection-third\r");
        try d.waitText(start, "selection-answer-three");
        try d.waitIdle(start);
        const final = try d.screen();
        try check(final.count("selection-answer-one") == 1 and final.count("selection-answer-two") == 1 and final.count("selection-answer-three") == 1);
        try check(final.count("selection-first") == 1 and final.count("selection-second") == 1 and final.count("selection-third") == 1);
        try check(final.row == 23 and final.count("/model") == 0);
    } else if (std.mem.eql(u8, mode, "log-failure")) {
        const start = d.used;
        try d.send("log-fixture-task\r");
        try d.waitText(start, "REC FAILED");
        try d.waitText(start, "log-fixture-answer");
        try d.waitIdle(start);
        try d.send("\x04");
        try d.finish(0);
        const final = try d.screen();
        try check(final.count(regular.prior) == 1 and final.count("log-fixture-answer") == 1);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "session recording disabled") != null);
        return;
    } else if (std.mem.eql(u8, mode, "auto-tools")) {
        // 同一终端两轮写入均无需审批；只提交任务并等待执行结果。
        for ([_][]const u8{ "auto-one", "auto-two" }) |prompt| {
            const start = d.used;
            try d.send(prompt);
            try d.send("\r");
            try d.waitText(start, "fixture-answer");
            try d.waitIdle(start);
            try check(std.mem.indexOf(u8, d.output[start..d.used], "Approval #") == null);
        }
    } else if (std.mem.eql(u8, mode, "keyboard-history")) {
        for ([_][]const u8{ "history-one", "history-two" }, 1..) |message, number| {
            const start = d.used;
            try d.send(message);
            try d.send("\r");
            const answer = try std.fmt.allocPrint(a, "history-answer-{d}", .{number});
            try d.waitText(start, answer);
            try d.waitIdle(start);
        }
        const EditorCheck = struct {
            fn expect(driver: *Driver, keys: []const u8, expected: []const u8) !void {
                try driver.send(keys);
                try driver.quiet(120);
                const state = try driver.screen();
                const row = &state.grid[23];
                const at = std.mem.indexOf(u8, row, "> ") orelse return error.EditorNotIdle;
                try check(std.mem.eql(u8, std.mem.trim(u8, row[at + 2 ..], " "), expected));
            }
        };
        try EditorCheck.expect(&d, "\x1b[A", "history-two");
        try EditorCheck.expect(&d, "\x1b[A", "history-one");
        try EditorCheck.expect(&d, "\x1b[B", "history-two");
        try EditorCheck.expect(&d, "\x1b[B", "");
        try EditorCheck.expect(&d, "manual-draft\x1b[A\x1b[B", "manual-draft");
        try EditorCheck.expect(&d, "\x15\x1b[A-edited\x1b[A\x1b[B", "history-two-edited");
        const start = d.used;
        try d.send("\x15esc-task\r");
        try d.waitBusy(start);
        try d.send("\x1b");
        try d.waitText(start, "Canceled; prior side effects remain");
        try d.waitIdle(start);
        try EditorCheck.expect(&d, "\x1b[A\x1b[A\x1b[A", "history-one");
        const again = d.used;
        try d.send("\r");
        try d.waitText(again, "after-esc-answer");
        try d.waitIdle(again);
    } else if (std.mem.eql(u8, mode, "esc-cancel-tool")) {
        const start = d.used;
        try d.send("esc-tool-task\r");
        try d.waitRunningFrame(start, "sleep 30");
        try d.send("\x1b");
        try d.waitText(start, "Canceled; prior side effects remain");
        try d.waitIdle(start);
        const again = d.used;
        try d.send("after-esc\r");
        try d.waitText(again, "after-esc-answer");
        try d.waitIdle(again);
    } else if (std.mem.eql(u8, mode, "cancel") or std.mem.eql(u8, mode, "term")) {
        // cancel / term：等待输入行模型流动色后的reset，证明任务已经启动。
        const start = d.used;
        try d.send("stall\r");
        try d.waitBusy(start);
        try d.quiet(250);

        if (std.mem.eql(u8, mode, "term")) {
            // term 模式：直接发送 SIGTERM，期望退出码 143（128 + 15）。
            try check(kill(pid, 15) == 0);
            try d.finish(143);
            return;
        }

        // Ctrl-C only opens the safe-default confirmation. Selection must
        // receive a complete owned frame before an independent Enter acts.
        try queuedKey(&d, a, "\x03", &.{"> Continue"});
        try queuedKey(&d, a, "\x1b[C", &.{"> Stop and clear"});
        try d.send("\r");
        try d.waitText(start, "Canceled");
        try d.waitIdle(start);

        // 取消后应能继续使用：再次提交 resume 并等待完成。
        const next = d.used;
        try d.send("resume\r");
        try d.waitIdle(next);
    } else {
        // 默认（交互）模式：验证 Unicode 输出，并在终端尺寸变化后界面仍能重绘。
        const start = d.used;
        try d.send("unicode\r");
        try d.waitIdle(start);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "世界") != null);

        // 依次把列宽改为40/80/120；每次确认模型输入前缀被重绘。
        for ([_]u16{ 40, 80, 120 }) |width| {
            size.col = width;
            const mark = d.used;
            // IOCSWINSZ 设置窗口尺寸，内核会向前台进程组发送 SIGWINCH，触发应用重绘。
            try check(c.ioctl(slave, std.os.linux.T.IOCSWINSZ, &size) == 0);
            try d.waitText(mark, "> ");
        }
    }

    // Remainder of the SAME read after Ctrl+D must not submit anything.
    try d.send(if (std.mem.eql(u8, mode, "exit-batched")) "\x04post-quit-must-not-submit\r" else "\x04");
    try d.finish(0);
    if (std.mem.eql(u8, mode, "resume-readonly")) {
        try check(std.mem.indexOf(u8, d.output[0..d.used], "thin --resume ") == null);
    } else if (full_resume or std.mem.eql(u8, mode, "resume-create")) {
        const prefix = "thin --resume ";
        const at = (std.mem.indexOf(u8, d.output[0..d.used], prefix) orelse return error.MissingResumeCommand) + prefix.len;
        const id = d.output[at..][0..32].*;
        if (full_resume) try check(std.mem.eql(u8, &id, restore_id));
    }
    if (std.mem.eql(u8, mode, "exit-no-submit") or std.mem.eql(u8, mode, "exit-unconfigured") or std.mem.eql(u8, mode, "exit-batched")) {
        const final = try d.screen();
        try check(final.row <= 7); // No screenful of blank rows between startup and exit identity.
        try check(final.count("Directory:") == 0 and final.count("Time:") == 0 and final.count("Session ID:") == 0);
        try check(final.count("thin --resume") == 0);
        const tail = std.mem.lastIndexOf(u8, d.output[0..d.used], "\x1b[?25h").? + "\x1b[?25h".len;
        try check(std.mem.trim(u8, d.output[tail..d.used], "\r\n").len == 0);
    }
    if (std.mem.eql(u8, mode, "date") or std.mem.eql(u8, mode, "log-idle") or std.mem.eql(u8, mode, "regular-two")) {
        const final = try d.screen();
        try check(final.count(regular.prior) == 1);
        if (std.mem.eql(u8, mode, "date")) try check(final.count("date-completed") == 1);
        if (std.mem.eql(u8, mode, "regular-two")) {
            try check(final.count("regular-answer-one") == 1 and final.count("regular-answer-two") == 1);
            try check(!final.visible("regular-answer-one")); // Actually reached scrollback.
        }
    }
}
