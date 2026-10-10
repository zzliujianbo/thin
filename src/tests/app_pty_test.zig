//! Linux x86_64 application PTY acceptance. Never opens the user's terminal.
//! 中文：Linux x86_64 应用级 PTY 验收驱动。它只使用 openpty 创建的伪终端，不会打开用户自己的终端。

const std = @import("std");
const c = std.c;
const abi = @import("../platform/terminal_abi.zig");
const openpty = abi.openpty;
const regular = @import("regular_screen.zig");

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

    /// Completion has no status label: the unstyled idle marker follows join.
    fn waitIdle(self: *Driver, start: usize) !void {
        try self.waitText(start, "] > ");
    }

    /// Fixed-size replay only: resize cases check sequences, not terminal reflow.
    fn screen(self: *const Driver) !regular.Screen {
        var result: regular.Screen = .{};
        try result.replay(self.output[0..self.used]);
        return result;
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

/// 验收入口：从环境变量读取二进制、项目目录、HOME 与测试 URL，创建 PTY 并 fork 启动应用，再按 THIN_APP_TEST_MODE 驱动对应的交互场景。
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

    // 子进程环境保持最小集合，并注入一个测试密钥，用于验证它不会出现在终端输出中。
    const env = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", home_env, "LANG=C.UTF-8", "TERM=xterm-256color", "THIN_FIXTURE_KEY=fixture-secret-never-log" };

    const interactive_argv = [_:null]?[*:0]const u8{bin};
    const print_argv = [_:null]?[*:0]const u8{ bin, "--print", "large-output" };
    // output 模式直接执行 --print 大输出；其余模式启动交互式界面。
    const argv: [*:null]const ?[*:0]const u8 = if (std.mem.eql(u8, mode, "output")) &print_argv else &interactive_argv;

    var master: c_int = undefined;
    var slave: c_int = undefined;

    var size = std.mem.zeroes(c.winsize);
    size.col = 80;
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

    // A complete composer frame shows the cursor; no statistics/status footer.
    try d.waitText(0, "\x1b[?25h");
    if (std.mem.eql(u8, mode, "auth-missing") or std.mem.eql(u8, mode, "auth-empty")) {
        // 初始化只验证待配置界面；不输入密钥或发送消息，避免连接默认公共端点。
        try d.waitText(0, "/auth");
    } else if (std.mem.eql(u8, mode, "auth-activate")) {
        // 待激活配置指向本地 fixture。/auth 使用独立的掩码输入，取消不能保存或污染聊天输入。
        try d.waitText(0, "/auth");
        var start = d.used;
        try d.send("/auth\r");
        try d.waitText(start, "API key");
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
        try d.send("/auth\r");
        try d.waitText(start, "API key");
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
    } else if (std.mem.eql(u8, mode, "stream-markdown")) {
        const start = d.used;
        try d.send("stream-task\r");
        try d.waitText(start, "reasoning-stage-one");
        try d.quiet(100);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Completed") == null);
        var stage = try d.screen();
        try check(stage.visible("reasoning-stage-one") and stage.row == 23);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Thinking") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "thin |") == null);
        try check(!stage.visible("thinking-old-one"));
        try check(stage.visible("thinking-old-two") and stage.visible("thinking-old-three"));
        try d.waitText(start, "reasoning-stage-two");
        try d.quiet(100);
        stage = try d.screen();
        try check(stage.visible("thinking-new-five") and stage.visible("thinking-new-six") and stage.visible("reasoning-stage-two"));
        try check(!stage.visible("reasoning-stage-one") and !stage.visible("thinking-old-two"));
        try check(std.mem.indexOf(u8, &stage.grid[23], "(fixture-model) [ctx ~") != null and std.mem.indexOf(u8, &stage.grid[23], "] ~") != null and stage.row == 23);
        for (stage.grid[22]) |byte| try check(byte == ' ');
        try check(!stage.visible("TPS:") and !stage.visible("tokens in:"));
        try d.waitText(start, "stream-stage-one");
        try d.quiet(100);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Completed") == null);
        stage = try d.screen();
        try check(stage.visible("Orange heading") and stage.visible("stream-stage-one") and stage.row == 23);
        try check(!stage.visible("reasoning-stage-two") and !stage.visible("Thinking"));
        try check(!stage.visible("Enter send") and !stage.visible("Ctrl+J newline"));
        try check(std.mem.indexOf(u8, d.output[start..d.used], "[user]") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "[assistant") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;208m") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[48;2;52;36;24m") != null);
        try d.waitText(start, "stream-final-answer");
        try d.waitIdle(start);
        try d.quiet(100);
        stage = try d.screen();
        try check(stage.count("reasoning-stage-one") == 0 and stage.count("reasoning-stage-two") == 0);
        try check(stage.count("thinking-new-five") == 0 and stage.count("stream-final-answer") == 1);
        try check(!stage.visible("TPS:") and !stage.visible("tokens in:") and !stage.visible("Completed"));
        try check(std.mem.indexOf(u8, &stage.grid[23], "(fixture-model) [ctx ~") != null);
        try check(stage.count("=> Final answer") == 1);
        for (stage.grid[22]) |byte| try check(byte == ' ');
        try check(stage.row == 23);
    } else if (std.mem.eql(u8, mode, "tool-icons")) {
        const start = d.used;
        try d.send("tool-icon-task\r");
        try d.waitText(start, "sleep 1; cat r.json");
        const animation_start = d.used;
        try d.quiet(120);
        const first = try d.screen();
        try d.quiet(240);
        const second = try d.screen();
        try check(first.visible(">_ sleep 1; cat r.json") and second.visible(">_ sleep 1; cat r.json"));
        // The ASCII VT fixture maps non-ASCII glyphs to '~'; inspect only these
        // renderer-owned braille symbols, not a general Unicode-width claim.
        var frames: usize = 0;
        for ([_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }) |icon| {
            if (std.mem.indexOf(u8, d.output[animation_start..d.used], icon) != null) frames += 1;
        }
        try check(frames >= 2);
        try check(first.row == 23 and second.row == 23);
        try check(std.mem.indexOf(u8, &first.grid[23], "(fixture-model) [ctx ~") != null and std.mem.indexOf(u8, &first.grid[23], "] ~") != null);
        for (first.grid[22]) |byte| try check(byte == ' ');
        try d.waitText(start, "tool-icon-final-answer");
        try d.waitIdle(start);
        try d.quiet(100);
        const final = try d.screen();
        try check(final.count("tool-icon-final-answer") == 1);
        var same_line = false;
        for (final.grid) |line| if (std.mem.indexOf(u8, &line, ">_ sleep 1;") != null and std.mem.indexOf(u8, &line, ">_ printf ok") != null and std.mem.indexOf(u8, &line, ">_ false [error]") != null) {
            same_line = true;
        };
        try check(same_line);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;114m>_ printf ok") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\x1b[38;5;203m>_ false [error]") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "bash #") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "tool-json-hidden-marker") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Running bash") == null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "Enter send") == null);
    } else if (std.mem.eql(u8, mode, "file-stats")) {
        const start = d.used;
        try d.send("file-stats-task\r");
        try d.waitText(start, "file-stats-final-answer");
        try d.waitIdle(start);
        const final = try d.screen();
        for ([_][]const u8{ "write_file stats.txt  ~0 +5 -0 lines", "write_file stats.txt  ~1 +1 -1 lines", "read_file stats.txt  5 lines", "read_file stats.txt  2 lines [partial]", "write_file stats.txt  ~0 +0 -5 lines", "write_file stats.txt [error]" }) |caption| try check(final.count(caption) == 1);
        try check(final.count("=> Final answer") == 1 and final.count("file-stats-final-answer") == 1);
        var header: ?usize = null;
        for (final.grid, 0..) |line, row| if (std.mem.indexOf(u8, &line, "=> Final answer") != null) {
            header = row;
        };
        try check(header != null and header.? > 0);
        for (final.grid[header.? - 1]) |byte| try check(byte == ' ');
        try check(std.mem.indexOf(u8, &final.grid[23], "(fixture-model) [ctx ~") != null);
        try check(std.mem.indexOf(u8, d.output[start..d.used], "\"written_bytes\"") == null);
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
    } else if (std.mem.eql(u8, mode, "cancel") or std.mem.eql(u8, mode, "term")) {
        // cancel / term：等待输入行模型流动色后的reset，证明任务已经启动。
        const start = d.used;
        try d.send("stall\r");
        try d.waitText(start, "\x1b[0m) ");
        try d.quiet(250);

        if (std.mem.eql(u8, mode, "term")) {
            // term 模式：直接发送 SIGTERM，期望退出码 143（128 + 15）。
            try check(kill(pid, 15) == 0);
            try d.finish(143);
            return;
        }

        // cancel 模式：发送 Ctrl-C（0x03），由应用取消当前任务。
        try d.send("\x03");
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

    // Ctrl-D (0x04) 让应用正常退出，期望退出码 0。
    try d.send("\x04");
    try d.finish(0);
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
