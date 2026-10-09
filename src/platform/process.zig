//! 子进程执行器（Linux + libc）：通过 /bin/bash -c 运行脚本，有界捕获 stdout/stderr，
//! 并以进程组为单位做 TERM -> KILL 的有界清理，保证取消或超时后不遗留后台进程。

const std = @import("std");
const p = @import("../core/protocol.zig");
const spawn = @import("spawn.zig");
// libc 与 Linux 系统调用接口。
const c = std.c;
const linux = std.os.linux;

// 查询 pid 所属进程组；用于判断子进程是否为自己进程组的组长。
extern "c" fn getpgid(pid: c.pid_t) c.pid_t;

/// 子进程运行参数（超时、输出预算、清理时间预算）。
pub const Options = struct {
    /// 整体超时（毫秒），超时后进入 TERM/KILL 清理。
    timeout_ms: u32 = 300000,
    /// stdout 与 stderr 合计的捕获预算（字节），超出部分以首尾加省略标记保留。
    output_bytes: u32 = 32768,
    /// 发送 TERM 后的宽限时间（毫秒），到期升级为 KILL。
    term_grace_ms: u32 = 1000,
    /// 清理阶段的总时间预算（毫秒），耗尽后报告 cleanup_failed。
    cleanup_timeout_ms: u32 = 5000,
    /// Anchor command cwd to the opened startup directory, not a replaceable path.
    cwd_dir: ?std.Io.Dir = null,
};

/// 运行结果。stdout/stderr 为渲染后的有界文本，由调用方传入的 allocator 分配，需由调用方释放。
pub const Result = struct {
    /// 渲染后的 stdout（已转义并按预算截断）。
    stdout: []const u8,
    /// 渲染后的 stderr。
    stderr: []const u8,
    /// 原始 stdout 字节总数（截断前）。
    stdout_bytes: u64,
    /// 原始 stderr 字节总数（截断前）。
    stderr_bytes: u64,
    /// 输出被截断、未读到 EOF，或清理失败时为 true。
    truncated: bool,
    /// 子进程退出状态；为 null 表示未能回收或未正常结束。
    term: ?std.process.Child.Term = null,
    /// 因超时而终止。
    timed_out: bool = false,
    /// 因取消（调用方取消或 Io 取消）而终止。
    canceled: bool = false,
    /// 清理未能确认成功（进程可能仍存活或未回收）；调用方不得将其视为成功终止。
    cleanup_failed: bool = false,
    /// Still-owned direct child, for diagnostics/reaping only; never signal a
    /// cached PID after this module has reaped it. Null if ownership was lost.
    unreaped_pid: ?c.pid_t = null,
};

// Keep raw prefix + rolling suffix. Preserve valid UTF-8, newlines and tabs;
// escape invalid bytes, terminal controls and directional-format controls.
// Sanitization is performed after draining, so split UTF-8 reads are harmless.
// Rendered head/marker/tail together fit the configured byte budget.
// 中文：渲染后的 head + 省略标记 + tail 合计不超过配置的字节预算。
/// 有界捕获器：前半缓冲保存输出前缀（head），后半作为环形缓冲保存最近输出（tail）。
const Capture = struct {
    /// 固定容量缓冲区，由调用方分配。
    data: []u8,
    /// 收到的原始字节总数（饱和累加），用于统计真实输出量。
    total: u64 = 0,
    /// tail 环形缓冲的下一个写入位置。
    tail_next: usize = 0,
    /// tail 中当前有效字节数，最大为 tail 容量。
    tail_len: usize = 0,
    /// 对应管道是否已读到 EOF。
    eof: bool = false,
    /// 输出是否因超预算或中间字节被丢弃而需要省略。
    omitted: bool = false,

    /// head 区长度：data 的前半部分（向上取整）。
    fn headSize(self: Capture) usize {
        return (self.data.len + 1) / 2;
    }

    /// 追加字节：前 headSize 个原始字节进入 head；之后的字节写入 tail 环形缓冲，覆盖最旧数据。
    fn add(self: *Capture, bytes: []const u8) void {
        const h = self.headSize();
        const tail = self.data[h..];
        for (bytes) |b| {
            // head 未满：按原始位置写入。
            if (self.total < h) {
                self.data[@intCast(self.total)] = b;
                // head 已满：写入 tail 环形区；tail_len 封顶为容量。
            } else if (tail.len != 0) {
                tail[self.tail_next] = b;
                self.tail_next = (self.tail_next + 1) % tail.len;
                self.tail_len = @min(self.tail_len + 1, tail.len);
            }
            // 饱和加，防止计数溢出。
            self.total +|= 1;
        }
    }

    /// 单个 token 的编码描述：raw 为消耗的原始字节数，width 为输出宽度，kind 为编码方式。默认值为转义，用于非法 UTF-8。
    const Token = struct { raw: usize = 1, width: usize = 4, kind: enum { plain, slash, escaped } = .escaped };
    /// 解析 bytes 开头的一个 token：决定它原样输出、反斜杠转义，还是转为 \xNN 形式。
    fn token(bytes: []const u8) Token {
        const b = bytes[0];
        // 反斜杠写成两个反斜杠，避免与转义序列混淆。
        if (b == '\\') return .{ .width = 2, .kind = .slash };
        // 普通换行、制表符与可打印 ASCII 原样保留。
        if (b == '\n' or b == '\t' or (b >= 32 and b <= 126)) return .{ .width = 1, .kind = .plain };

        // 非法首字节：按单字节转义（默认 Token）。
        const len = std.unicode.utf8ByteSequenceLength(b) catch return .{};
        if (b < 128 or bytes.len < len) return .{};
        const cp = std.unicode.utf8Decode(bytes[0..len]) catch return .{};
        // 不可见控制符、零宽字符、双向格式控制符等可能篡改终端显示，需要转义。
        const unsafe = (cp >= 0x80 and cp <= 0x9f) or cp == 0xad or cp == 0x61c or
            cp == 0x200b or cp == 0x200e or cp == 0x200f or
            (cp >= 0x2028 and cp <= 0x202e) or cp == 0x2060 or
            (cp >= 0x2066 and cp <= 0x2069) or cp == 0xfeff;
        // 不安全的多字节字符整体转义，每个字节输出为 \xNN（宽度为 len*4）。
        return .{ .raw = len, .width = if (unsafe) @as(usize, len) * 4 else len, .kind = if (unsafe) .escaped else .plain };
    }

    /// 按 token 类型把 bytes 编码到 dst（dst 空间由调用方保证足够）。
    fn encode(dst: []u8, bytes: []const u8, t: Token) void {
        switch (t.kind) {
            .plain => @memcpy(dst[0..t.width], bytes[0..t.raw]),
            .slash => @memcpy(dst[0..2], "\\\\"),
            .escaped => {
                const hex = "0123456789abcdef";
                for (bytes[0..t.raw], 0..) |b, i| {
                    const out = dst[i * 4 ..][0..4];
                    @memcpy(out[0..2], "\\x");
                    out[2] = hex[b >> 4];
                    out[3] = hex[b & 15];
                }
            },
        }
    }

    /// 尽量把 bytes 完整编码进 dst，返回已使用宽度。放不下的 token 整体停止，不切断转义序列或 UTF-8 字符。
    fn encodeSlice(dst: []u8, bytes: []const u8) usize {
        var offset: usize = 0;
        var used: usize = 0;
        while (offset < bytes.len) {
            const t = token(bytes[offset..]);
            if (used + t.width > dst.len) break;
            encode(dst[used..], bytes[offset..], t);
            offset += t.raw;
            used += t.width;
        }
        return used;
    }

    /// 从末尾向前挑选宽度不超过 budget 的完整 token，返回起始下标，用于保留最近的输出。
    fn suffixStart(bytes: []const u8, budget: usize) usize {
        var end = bytes.len;
        var used: usize = 0;
        while (end > 0) {
            var start = end - 1;
            // 回退跳过 UTF-8 续字节（10xxxxxx），找到字符起点，最多回退 4 字节。
            while (start > 0 and bytes[start] & 0xc0 == 0x80 and end - start < 4) start -= 1;
            var t = token(bytes[start..end]);
            // 若从字符起点解析的长度不一致，说明字符被切断，退回单字节处理。
            if (t.raw != end - start) {
                start = end - 1;
                t = token(bytes[start..end]);
            }
            if (used + t.width > budget) break;
            used += t.width;
            end = start;
        }
        return end;
    }

    /// 生成最终输出：未省略时编码全部保留内容；超预算或有丢弃时编码为 head + "[...]" + tail。返回值由 allocator 分配。
    fn render(self: *Capture, allocator: std.mem.Allocator) ![]const u8 {
        const h = self.headSize();
        const head_len: usize = @intCast(@min(self.total, h));
        const tail = self.data[h..][0..self.tail_len];
        // tail 环形缓冲已满时，把最旧字节旋转到开头，使 tail 按时间顺序排列。
        if (tail.len != 0 and self.tail_len == self.data.len - h) std.mem.rotate(u8, tail, self.tail_next);
        const kept = self.data[0 .. head_len + self.tail_len];

        var encoded: usize = 0;
        var offset: usize = 0;
        while (offset < kept.len) {
            const t = token(kept[offset..]);
            encoded += t.width;
            offset += t.raw;
        }
        // 原始字节数超过缓冲容量，说明中间有被丢弃的区间。
        const dropped_raw = self.total > self.data.len;
        // 有丢弃，或编码后超预算，都需要省略标记。
        self.omitted = dropped_raw or encoded > self.data.len;

        const dst = try allocator.alloc(u8, self.data.len);
        defer allocator.free(dst);

        var n: usize = 0;
        if (!self.omitted) {
            n = encodeSlice(dst, kept);
        } else {
            const marker = "\n[...]\n";
            // 预算极小，连完整标记都放不下时，只返回标记的前缀。
            if (dst.len < marker.len) return allocator.dupe(u8, marker[0..dst.len]);
            // 扣除标记后的预算平分：左侧为 head，右侧为 tail。
            const left = (dst.len - marker.len + 1) / 2;
            // Never decode a UTF-8 sequence across an omitted raw interval.
            const prefix = if (dropped_raw) kept[0..head_len] else kept;
            const suffix = if (dropped_raw) tail else kept;
            n = encodeSlice(dst[0..left], prefix);
            @memcpy(dst[n..][0..marker.len], marker);
            n += marker.len;
            // 尾部从完整字符边界开始，保证输出仍是合法 UTF-8。
            const start = suffixStart(suffix, dst.len - n);
            n += encodeSlice(dst[n..], suffix[start..]);
        }
        return allocator.dupe(u8, dst[0..n]);
    }
};

/// 将管道设为 O_NONBLOCK：无数据时 read 立即返回 EAGAIN，轮询循环不会被阻塞。
fn nonblocking(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return error.PipeFlagsFailed;
    const nonblock: u32 = @bitCast(c.O{ .NONBLOCK = true });
    if (c.fcntl(fd, c.F.SETFL, flags | @as(c_int, @intCast(nonblock))) < 0)
        return error.PipeFlagsFailed;
}

// One bounded batch per stream: a hot stdout must not starve stderr, timeout,
// or cancellation. Raw nonblocking read returns 0 at EOF (Io.File would return
// error.EndOfStream). There are no pipe workers and no allocator concurrency.
// 中文：每次 drain 对每路最多读 8 批（每批 8KiB）后返回，保证 stdout 与 stderr 公平。无额外线程，因此无需同步。
/// 从 fd 读取一批数据到 capture。EOF 时置位 capture.eof；EAGAIN/EINTR 视为暂时无数据。
fn drain(fd: c.fd_t, capture: *Capture) !void {
    if (capture.eof) return;
    var buf: [8192]u8 = undefined;
    for (0..8) |_| {
        // n>0 收集数据；n==0 为 EOF（不是错误）；n<0 时按 errno 区分暂时无数据与真实错误。
        const n = c.read(fd, &buf, buf.len);
        if (n > 0) {
            capture.add(buf[0..@intCast(n)]);
        } else if (n == 0) {
            capture.eof = true;
            return;
        } else switch (std.posix.errno(n)) {
            .AGAIN, .INTR => return,
            else => return error.PipeReadFailed,
        }
    }
}

/// 非阻塞且不回收地检查子进程是否已退出（WNOWAIT）。返回 true 表示已退出；ECHILD 表示所有权已丢失。
fn observedExit(pid: c.pid_t) !bool {
    var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
    const rc = linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null);
    // si_pid 非 0 表示子进程已可等待；WNOWAIT 让状态保留给之后的 waitpid 回收。
    return switch (linux.errno(rc)) {
        .SUCCESS => info.fields.common.first.piduid.pid != 0,
        .INTR => false,
        // 子进程已被他人回收，此后不得再对该 PID 发信号（它可能已被复用）。
        .CHILD => error.ChildOwnershipLost,
        else => error.WaitFailed,
    };
}

/// 向 pid 发送信号。ESRCH（目标已不存在）视为成功，因为目标已经结束；其他失败返回 false。
fn signal(pid: c.pid_t, sig: c.SIG) bool {
    const rc = c.kill(pid, sig);
    return rc == 0 or std.posix.errno(rc) == .SRCH;
}

/// 自 start 起经过的毫秒数，基于 awake 时钟（不受系统挂起或时间调整影响）。
fn elapsed(io: std.Io, start: std.Io.Timestamp) i64 {
    return start.untilNow(io, .awake).toMilliseconds();
}

// Linux /proc must expose this PID namespace. Unlike kill(-pgid, 0), this
// distinguishes harmless orphan zombies from live descendants. No credentials
// or process environments are read. A failed/incomplete scan is NOT success.
// 中文：扫描失败或不完整时返回错误而不是 false，避免误判为“进程组已清空”。
/// 扫描 /proc，判断进程组 pgid 中是否仍有非僵尸进程。
fn groupAlive(io: std.Io, pgid: c.pid_t, start: std.Io.Timestamp, budget: u32) !bool {
    const dir = c.opendir("/proc") orelse return error.ProcUnavailable;
    defer _ = c.closedir(dir);

    // 必须看到组长本身，否则 PID 命名空间可能不一致，结果不可信。
    var found_leader = false;
    while (true) {
        // 扫描同样受清理预算约束，超时即返回错误。
        if (elapsed(io, start) >= budget) return error.CleanupDeadline;
        // 清零 errno：readdir 返回 NULL 时需用 errno 区分“读完”与“出错”。
        c._errno().* = 0;
        const entry = c.readdir(dir) orelse {
            if (c._errno().* != 0) return error.ProcUnavailable;
            break;
        };
        const name = std.mem.sliceTo(&entry.name, 0);
        const pid = std.fmt.parseInt(c.pid_t, name, 10) catch continue;
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/stat", .{pid}, 0);
        // 进程可能在 readdir 与 open 之间退出，NOENT 视为跳过。
        const fd = c.open(path, .{ .CLOEXEC = true });
        if (fd < 0) {
            if (std.posix.errno(fd) == .NOENT) continue;
            return error.ProcUnavailable;
        }
        var buf: [4096]u8 = undefined;
        const n = c.read(fd, &buf, buf.len);
        const read_errno = std.posix.errno(n);
        _ = c.close(fd);
        // 进程可能在 open 与 read 之间退出（ESRCH），跳过；其他失败视为 /proc 不可用。
        if (n <= 0) {
            // A process may disappear between readdir/open/read.
            if (n < 0 and read_errno == .SRCH) continue;
            return error.ProcUnavailable;
        }

        const stat = buf[0..@intCast(n)];

        // comm 字段可能含空格或括号，因此从最后一个 ')' 之后再解析其余字段。
        const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.BadProcStat;
        var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
        const state = fields.next() orelse return error.BadProcStat;
        _ = fields.next() orelse return error.BadProcStat; // ppid
        const group = try std.fmt.parseInt(c.pid_t, fields.next() orelse return error.BadProcStat, 10);

        // 记录组长是否在 /proc 中可见。
        if (pid == pgid and group == pgid) found_leader = true;

        // 只有非僵尸、非死亡进程才算存活；僵尸只占用 PID，不再产生 I/O 或子进程。
        if (group == pgid and !std.mem.eql(u8, state, "Z") and !std.mem.eql(u8, state, "X")) return true;
    }

    // 组长不可见说明命名空间不一致，结果不可信，返回错误。
    if (!found_leader) return error.ProcNamespaceMismatch;
    return false;
}

/// Linux + libc implementation. Caller must not reap this child from another
/// thread or install SIGCHLD=SIG_IGN/SA_NOCLDWAIT. Escaped process groups are not
/// owned. Cleanup is bounded; cleanup_failed can mean an unreaped/still-live
/// child, and must not be presented as successful termination by the caller.
/// 中文：运行脚本并返回有界结果。调用方须保证不在其他线程回收该子进程，也不得设置 SIGCHLD 为忽略。
/// 逃逸出本进程组的后代不受管理。cleanup_failed 为真时，子进程可能仍存活或未被回收，不能视为成功终止。
pub fn run(allocator: std.mem.Allocator, io: std.Io, root: []const u8, script: []const u8, environ: *const std.process.Environ.Map, options: Options, cancel: *const p.Cancellation) !Result {
    return runExecutable(allocator, io, root, script, environ, options, cancel, .{});
}

// Private launch seam exercises execve failure and a stalled startup without
// replacing system binaries or changing the public shell execution contract.
const Launch = struct {
    executable: []const u8 = "/bin/bash",
    test_mode: spawn.TestMode = .none,
    test_cancel_after_fork: ?*p.Cancellation = null,
};

fn runExecutable(allocator: std.mem.Allocator, io: std.Io, root: []const u8, script: []const u8, environ: *const std.process.Environ.Map, options: Options, cancel: *const p.Cancellation, launch: Launch) !Result {
    // 仅支持 Linux：依赖 waitid、/proc 与 poll。
    if (@import("builtin").os.tag != .linux) return error.UnsupportedPlatform;
    var result: Result = .{ .stdout = "", .stderr = "", .stdout_bytes = 0, .stderr_bytes = 0, .truncated = false };

    // 启动前已取消：不 spawn 任何进程，直接返回 canceled。
    if (cancel.isRequested()) {
        result.canceled = true;
        return result;
    }

    // Io 层取消同样视为未启动。
    io.checkCancel() catch {
        result.canceled = true;
        return result;
    };

    // 两路输出各占一半预算：stdout 向上取整，stderr 向下取整，合计恰为 output_bytes。
    var out: Capture = .{ .data = try allocator.alloc(u8, (options.output_bytes + @as(u64, 1)) / 2) };
    defer allocator.free(out.data);
    var err: Capture = .{ .data = try allocator.alloc(u8, options.output_bytes / 2) };
    defer allocator.free(err.data);

    // 计时起点，用于超时与清理期限（spawn 之前记录）。
    const start = std.Io.Clock.awake.now(io);
    // pgid=0：子进程成为新进程组的组长，之后可对 -pid 整组发信号。
    // 子进程不读 stdin，避免交互式输入造成阻塞。
    // 自有启动层在 fork 后始终返回 PID；chdir/exec 失败也进入下面的有界清理。
    const child = try spawn.start(allocator, root, options.cwd_dir, launch.executable, script, environ, launch.test_mode);

    // Never call Child.wait/kill: canceled wait can erase ownership; kill uses
    // TERM and an unbounded wait. Hold the PID until the LAST group signal.
    // 中文：不要调用 Child.wait/kill：取消中的 wait 可能丢失所有权，kill 也是无界等待。这里持有 PID，直到最后一次进程组信号发出为止。
    const pid = child.pid;
    // 无论从哪个分支返回，都关闭管道读端（包括启动错误管道）。
    defer child.close();
    if (comptime @import("builtin").is_test) {
        if (launch.test_cancel_after_fork) |token| token.cancel();
    }

    // PID 0 或 1 发信号会影响整个进程组或 init 进程，必须拒绝。
    // Linux fork 在父进程中只会返回 >1 的子 PID；启动层不转交 0/-1。
    std.debug.assert(pid > 1);

    // 仅当子进程确为自己进程组的组长时，才能安全地对整组（-pid）发信号；否则只对单个 PID 发信号，并视为清理未验证。
    const group_owned = getpgid(pid) == pid;

    // 记录首个错误；清理结束后再统一返回。
    var failure: ?anyerror = if (group_owned) null else error.UnverifiedProcessGroup;
    if (!group_owned) result.cleanup_failed = true;
    if (child.signal_restore_failed) {
        failure = error.SpawnSignalFailed;
        result.cleanup_failed = true;
    }

    var out_ready = true;
    var err_ready = true;

    // 管道设为非阻塞；设置失败则停止读取该管道，但仍继续完成清理。
    nonblocking(child.stdout) catch |e| {
        failure = e;
        out_ready = false;
    };
    nonblocking(child.stderr) catch |e| {
        failure = e;
        err_ready = false;
    };

    // 非 null 表示已进入清理阶段，并记录清理开始时刻。
    var cleaning: ?std.Io.Timestamp = null;
    var exited = false;
    var killed = false;

    // ownership=false 表示 PID 所有权已丢失（被他人回收），此后绝不再发信号。
    var ownership = true;
    var launch_status: spawn.Status = .pending;

    while (true) {
        // 启动握手与输出共享同一有界循环，不在 exec 错误管道上同步等待。
        if (launch_status == .pending) {
            launch_status = spawn.status(child.exec_error) catch |e| blk: {
                failure = e;
                break :blk .failed;
            };
            if (launch_status == .failed and failure == null) failure = error.SpawnFailed;
        }
        // 每轮先排空两路管道，避免子进程因管道写满而阻塞。
        if (out_ready) drain(child.stdout, &out) catch |e| {
            failure = e;
            out_ready = false;
        };
        if (err_ready) drain(child.stderr, &err) catch |e| {
            failure = e;
            err_ready = false;
        };

        // 非阻塞检查退出；出错时记录，所有权丢失则停止。
        if (!exited) exited = observedExit(pid) catch |e| blk: {
            failure = e;
            if (e == error.ChildOwnershipLost) ownership = false;
            break :blk false;
        };

        if (!ownership) {
            result.cleanup_failed = true;
            break; // Never signal an ID after ownership has been lost.
        }

        // 取消不立即返回，而是进入有界清理流程。
        io.checkCancel() catch {
            result.canceled = true;
        };
        result.canceled = result.canceled or cancel.isRequested();

        // 进入清理的条件：已退出（需收拾残留后代）、出错、被取消或超时。先发 TERM，请求优雅退出。
        if (cleaning == null) {
            result.timed_out = !exited and elapsed(io, start) >= options.timeout_ms;
            if (exited or failure != null or result.canceled or result.timed_out) {
                cleaning = std.Io.Clock.awake.now(io);
                if (!signal(if (group_owned) -pid else pid, .TERM)) result.cleanup_failed = true;
            }
        }

        // 清理阶段：超过宽限期后升级为 KILL；cleanup 预算需为 KILL 预留时间。
        if (cleaning) |since| {
            const age = elapsed(io, since);
            // Reserve time after KILL even when grace exceeds cleanup budget.
            if (!killed and age >= @min(options.term_grace_ms, options.cleanup_timeout_ms / 2)) {
                if (!signal(if (group_owned) -pid else pid, .KILL)) result.cleanup_failed = true;
                killed = true;
            }
            // 子进程已退出且管道已 EOF（或不再读）时，检查进程组是否还有残留后代；全部消失才结束循环。
            if (exited and launch_status != .pending and group_owned and (out.eof or !out_ready) and (err.eof or !err_ready)) {
                // 无法确认时保守地视为仍存活，继续等待直到预算耗尽。
                const alive = groupAlive(io, pid, since, options.cleanup_timeout_ms) catch true;
                if (!alive) break;
            }
            // 清理预算耗尽：补发 KILL，报告 cleanup_failed，并放弃等待。
            if (age >= options.cleanup_timeout_ms) {
                if (!killed) _ = signal(if (group_owned) -pid else pid, .KILL);
                result.cleanup_failed = true;
                break;
            }
        }

        // 已 EOF 或已停用的管道用 fd=-1 表示，poll 会忽略它。
        var fds = [_]c.pollfd{
            .{ .fd = if (out_ready and !out.eof) child.stdout else -1, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = if (err_ready and !err.eof) child.stderr else -1, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = if (launch_status == .pending) child.exec_error else -1, .events = c.POLL.IN, .revents = 0 },
        };

        // Bounded libc poll is deliberately not an Io cancellation point.
        // 5ms 超时：兼顾退出与取消的响应速度，又避免忙等。
        const rc = c.poll(&fds, fds.len, 5);
        if (rc < 0 and std.posix.errno(rc) != .INTR) failure = error.PollFailed;
    }

    // No group signals below this line, including error/defer paths.
    // 中文：此行之后不再发送任何进程组信号（包括错误路径）。
    if (ownership) {
        var status: c_int = 0;
        // 非阻塞回收；EINTR 在清理预算内重试。
        var rc = c.waitpid(pid, &status, linux.W.NOHANG);
        while (rc < 0 and std.posix.errno(rc) == .INTR and elapsed(io, cleaning.?) < options.cleanup_timeout_ms)
            rc = c.waitpid(pid, &status, linux.W.NOHANG);
        // 回收成功：记录真实退出状态。
        if (rc == pid) {
            result.term = std.Io.Threaded.statusToTerm(@bitCast(status));
        } else {
            result.cleanup_failed = true;
            // 未能回收：rc==0 表示仍在运行，EINTR 亦然；此时保留 PID 供调用方诊断。
            if (rc == 0 or (rc < 0 and std.posix.errno(rc) != .CHILD)) result.unreaped_pid = pid;
        }
    }

    result.stdout_bytes = out.total;
    result.stderr_bytes = err.total;

    // Do not allow an allocation error while formatting output to mask a live
    // or unreaped child. This failure path performs no further allocations.
    if (result.cleanup_failed) {
        result.truncated = true;
        return result;
    }

    // 清理确认成功后，才把之前记录的 I/O 或轮询错误返回。
    if (failure) |e| return e;

    result.stdout = try out.render(allocator);
    errdefer allocator.free(result.stdout);
    result.stderr = try err.render(allocator);

    // 发生省略或未读到 EOF，都说明输出不完整。
    result.truncated = out.omitted or err.omitted or !out.eof or !err.eof;
    return result;
}

// 测试上下文：临时目录、根路径，以及最小环境变量映射。
const TestContext = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    root: []const u8,

    fn init() !TestContext {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [4096]u8 = undefined;
        const n = try tmp.dir.realPath(std.testing.io, &buf);
        const root = try std.testing.allocator.dupe(u8, buf[0..n]);
        errdefer std.testing.allocator.free(root);

        var env = std.process.Environ.Map.init(std.testing.allocator);
        errdefer env.deinit();
        try env.put("PATH", "/usr/bin:/bin");
        try env.put("LANG", "C");
        return .{ .tmp = tmp, .env = env, .root = root };
    }

    fn deinit(self: *TestContext) void {
        self.tmp.cleanup();
        self.env.deinit();
        std.testing.allocator.free(self.root);
    }
};

/// 释放测试中 run 返回的 stdout 与 stderr。
fn freeResult(result: Result) void {
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
}

// 测试统一使用较短的超时与清理预算，加快测试速度。
const test_options: Options = .{ .timeout_ms = 1500, .term_grace_ms = 40, .cleanup_timeout_ms = 500 };

// 验证退出码、工作目录、stdin 被忽略，以及环境变量过滤。
test "exit7, cwd, ignored stdin and explicit filtered environment" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // Construct the pre-filter input locally; never inspect ambient credentials.
    var unfiltered = std.process.Environ.Map.init(std.testing.allocator);
    defer unfiltered.deinit();
    try unfiltered.put("ENVSECRET", "fake-test-secret");
    try unfiltered.put("SAFE", "allowed");
    try ctx.env.put("SAFE", unfiltered.get("SAFE").?);
    var cancel: p.Cancellation = .{};
    const r = try run(std.testing.allocator, std.testing.io, ctx.root, "test -z \"${ENVSECRET+x}\" || exit 91; test \"$SAFE\" = allowed || exit 92; read x && exit 93; test \"$PWD\" = \"$EXPECTED_ROOT\" || exit 94; printf ok; exit 7", blk: {
        try ctx.env.put("EXPECTED_ROOT", ctx.root);
        break :blk &ctx.env;
    }, test_options, &cancel);
    defer freeResult(r);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, r.term.?);
    try std.testing.expectEqualStrings("ok", r.stdout);
    try std.testing.expect(!r.cleanup_failed and !r.truncated);
}

// Only inspect our own descriptors/direct children; never reap an unspecified
// PID or scan/signals unrelated processes to repair a failed launch.
fn ownFdCount() !usize {
    const dir = c.opendir("/proc/self/fd") orelse return error.ProcUnavailable;
    defer _ = c.closedir(dir);
    var count: usize = 0;
    while (true) {
        c._errno().* = 0;
        const entry = c.readdir(dir) orelse {
            if (c._errno().* != 0) return error.ProcUnavailable;
            break;
        };
        if (entry.name[0] != '.') count += 1;
    }
    return count;
}

fn ownChildren(buf: []u8) ![]const u8 {
    const fd = c.open("/proc/thread-self/children", .{ .CLOEXEC = true });
    if (fd < 0) return error.ProcUnavailable;
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    if (n < 0 or n == buf.len) return error.ProcUnavailable;
    return buf[0..@intCast(n)];
}

test "failed chdir fchdir and exec launches repeatedly leave no fds or children" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    const missing = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing", .{ctx.root});
    defer std.testing.allocator.free(missing);
    var before_buf: [4096]u8 = undefined;
    var after_buf: [4096]u8 = undefined;
    const children = try ownChildren(&before_buf);
    // A valid owned fd that is not a directory exercises post-fork fchdir,
    // rather than a pre-fork invalid-descriptor rejection.
    const file = try ctx.tmp.dir.createFile(std.testing.io, "not-a-directory", .{});
    defer file.close(std.testing.io);
    var bad_anchor = test_options;
    bad_anchor.cwd_dir = .{ .handle = file.handle };
    const fds = try ownFdCount();
    for (0..32) |_| {
        try std.testing.expectError(error.SpawnFailed, run(std.testing.allocator, std.testing.io, missing, "exit 0", &ctx.env, test_options, &cancel));
        try std.testing.expectError(error.SpawnFailed, runExecutable(std.testing.allocator, std.testing.io, ctx.root, "exit 0", &ctx.env, test_options, &cancel, .{ .executable = missing }));
        try std.testing.expectError(error.SpawnFailed, run(std.testing.allocator, std.testing.io, ctx.root, "exit 0", &ctx.env, bad_anchor, &cancel));
        try std.testing.expectEqual(fds, try ownFdCount());
        try std.testing.expectEqualStrings(children, try ownChildren(&after_buf));
    }
}

test "pre-exec error pipe wait remains bounded by cancellation and timeout" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    const fds = try ownFdCount();
    var before: [4096]u8 = undefined;
    var after: [4096]u8 = undefined;
    const children = try ownChildren(&before);
    for ([_]bool{ false, true }) |cancel_after_fork| {
        var cancel: p.Cancellation = .{};
        const start = std.Io.Clock.awake.now(std.testing.io);
        const r = try runExecutable(std.testing.allocator, std.testing.io, ctx.root, "printf should-not-execute", &ctx.env, .{ .timeout_ms = 80, .term_grace_ms = 20, .cleanup_timeout_ms = 500 }, &cancel, .{
            .test_mode = .stop_before_exec,
            .test_cancel_after_fork = if (cancel_after_fork) &cancel else null,
        });
        defer freeResult(r);
        try std.testing.expectEqual(cancel_after_fork, r.canceled);
        try std.testing.expectEqual(!cancel_after_fork, r.timed_out);
        try std.testing.expect(!r.cleanup_failed and r.unreaped_pid == null);
        try std.testing.expectEqual(@as(u64, 0), r.stdout_bytes);
        if (!cancel_after_fork) try std.testing.expectEqual(std.process.Child.Term{ .signal = .KILL }, r.term.?);
        try std.testing.expect(elapsed(std.testing.io, start) < 1000);
        try std.testing.expectEqual(fds, try ownFdCount());
        try std.testing.expectEqualStrings(children, try ownChildren(&after));
    }
}

// 验证两路大输出：首尾得以保留，且原始字节数精确统计。
test "two large pipes preserve prefix suffix and exact counts" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    const r = try run(std.testing.allocator, std.testing.io, ctx.root, "printf HEAD; printf '%131072s' ''; printf TAIL; printf ERRH >&2; printf '%131072s' '' >&2; printf ERRT >&2", &ctx.env, .{ .output_bytes = 64, .timeout_ms = 1500, .term_grace_ms = 20, .cleanup_timeout_ms = 500 }, &cancel);
    defer freeResult(r);
    try std.testing.expectEqual(@as(u64, 131080), r.stdout_bytes);
    try std.testing.expectEqual(@as(u64, 131080), r.stderr_bytes);
    try std.testing.expectEqual(@as(usize, 32), r.stdout.len);
    try std.testing.expectEqual(@as(usize, 32), r.stderr.len);
    try std.testing.expect(std.mem.startsWith(u8, r.stdout, "HEAD"));
    try std.testing.expect(std.mem.endsWith(u8, r.stdout, "TAIL"));
    try std.testing.expect(std.mem.startsWith(u8, r.stderr, "ERRH"));
    try std.testing.expect(std.mem.endsWith(u8, r.stderr, "ERRT"));
    try std.testing.expect(r.truncated and !r.cleanup_failed);
}

// 验证启动前取消：即使 cwd 不存在也不会 spawn。
test "precancel does not spawn even with nonexistent cwd" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    cancel.cancel();
    const r = try run(std.testing.allocator, std.testing.io, "/nonexistent-thin-test-root", "exit 91", &ctx.env, test_options, &cancel);
    defer freeResult(r);
    try std.testing.expect(r.canceled and r.term == null and !r.cleanup_failed);
}

/// 轮询等待 ready 文件出现（最多约 1 秒），用于确认子进程已启动。
fn waitReady(io: std.Io, dir: std.Io.Dir) !void {
    const start = std.Io.Clock.awake.now(io);
    while (elapsed(io, start) < 1000) {
        const file = dir.openFile(io, "ready", .{}) catch |e| switch (e) {
            error.FileNotFound => {
                try std.Io.sleep(io, .fromMilliseconds(2), .awake);
                continue;
            },
            else => return e,
        };
        file.close(io);
        return;
    }
    return error.TestReadyTimeout;
}

/// 等待子进程就绪后触发取消，用于测试运行中取消。
fn cancelWhenReady(io: std.Io, dir: std.Io.Dir, cancel: *p.Cancellation) !void {
    try waitReady(io, dir);
    cancel.cancel();
}

// 验证运行中取消会终止子进程。
test "running cancellation terminates child" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    var task = try std.Io.concurrent(std.testing.io, cancelWhenReady, .{ std.testing.io, ctx.tmp.dir, &cancel });
    defer task.cancel(std.testing.io) catch {};
    const r = try run(std.testing.allocator, std.testing.io, ctx.root, "printf ready; : > ready; while (( SECONDS < 2 )); do :; done", &ctx.env, test_options, &cancel);
    defer freeResult(r);
    try task.await(std.testing.io);
    try std.testing.expect(r.canceled and !r.timed_out and !r.cleanup_failed);
    try std.testing.expectEqualStrings("ready", r.stdout);
    try std.testing.expect(r.term != null);
}

// 验证超时：普通进程被 TERM 结束，忽略 TERM 的进程需要 KILL 升级。
test "timeout and TERM ignoring KILL escalation" {
    var ctx = try TestContext.init();
    defer ctx.deinit();

    // 两个脚本分别对应普通进程与忽略 TERM 的进程。
    for ([_][]const u8{ "printf ready; while (( SECONDS < 2 )); do :; done", "trap '' TERM; printf ready; while (( SECONDS < 2 )); do :; done" }, 0..) |script, i| {
        var cancel: p.Cancellation = .{};
        const r = try run(std.testing.allocator, std.testing.io, ctx.root, script, &ctx.env, .{ .timeout_ms = 100, .term_grace_ms = 40, .cleanup_timeout_ms = 500 }, &cancel);
        defer freeResult(r);
        try std.testing.expect(r.timed_out and !r.canceled and !r.cleanup_failed);
        try std.testing.expectEqualStrings("ready", r.stdout);
        try std.testing.expectEqual(std.process.Child.Term{ .signal = if (i == 0) .TERM else .KILL }, r.term.?);
    }
}

// 验证 shell 正常退出后，仍持有管道的后台后代（包括忽略 TERM 的）也会被清理。
test "normal shell exit cleans background pipe holders, including TERM ignoring descendants" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    const start = std.Io.Clock.awake.now(std.testing.io);
    const r = try run(std.testing.allocator, std.testing.io, ctx.root, "(trap '' TERM; while (( SECONDS < 2 )); do :; done) & printf done; exit 7", &ctx.env, test_options, &cancel);
    defer freeResult(r);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, r.term.?);
    try std.testing.expect(!r.timed_out and !r.canceled and !r.cleanup_failed);
    try std.testing.expect(elapsed(std.testing.io, start) < 1200);
}

// 验证外层 Io 取消时仍能完成有界清理。
test "outer Io cancellation still completes bounded cleanup" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    var task = try std.Io.concurrent(std.testing.io, run, .{ std.testing.allocator, std.testing.io, ctx.root, "trap '' TERM; printf ready; : > ready; while (( SECONDS < 2 )); do :; done", &ctx.env, test_options, &cancel });

    // 标记结果是否已被 task.cancel 取走，防止 defer 重复释放。
    var consumed = false;
    defer if (!consumed) {
        if (task.cancel(std.testing.io)) |r| freeResult(r) else |_| {}
    };
    try waitReady(std.testing.io, ctx.tmp.dir);
    const r = try task.cancel(std.testing.io);
    consumed = true;
    defer freeResult(r);
    try std.testing.expect(r.canceled and !r.cleanup_failed);
    try std.testing.expectEqual(std.process.Child.Term{ .signal = .KILL }, r.term.?);
    try std.testing.expectEqualStrings("ready", r.stdout);
}

// 验证后代已关闭管道但仍存活时，正常退出同样会清理它们。
test "normal exit also cleans descendants that closed both pipes" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    const r = try run(std.testing.allocator, std.testing.io, ctx.root, "(trap '' TERM; exec >/dev/null 2>&1; while (( SECONDS < 2 )); do :; done) & exit 7", &ctx.env, test_options, &cancel);
    defer freeResult(r);
    try std.testing.expect(!r.cleanup_failed);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, r.term.?);
}

// 验证清理预算耗尽时明确报告失败，且测试自身负责回收子进程。
test "exhausted cleanup deadline is explicitly reported, never successful" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var cancel: p.Cancellation = .{};
    const r = try run(std.testing.allocator, std.testing.io, ctx.root, "trap '' TERM; printf '%s' \"$$\"; while (( SECONDS < 2 )); do :; done", &ctx.env, .{ .timeout_ms = 100, .cleanup_timeout_ms = 0 }, &cancel);
    defer freeResult(r);
    try std.testing.expect(r.cleanup_failed and r.timed_out);

    // The runner honestly relinquishes cleanup after its zero budget. The test
    // remains responsible for reaping its own child; never signal after reap.
    const pid = r.unreaped_pid orelse 0;
    const start = std.Io.Clock.awake.now(std.testing.io);
    while (r.term == null) {
        try std.testing.expect(pid > 1);
        var status: c_int = 0;
        const rc = c.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == pid or (rc < 0 and std.posix.errno(rc) == .CHILD)) break;
        try std.testing.expect(rc == 0 or std.posix.errno(rc) == .INTR);
        try std.testing.expect(elapsed(std.testing.io, start) < 2500);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
}

// 验证 output_bytes=0 时仍完整排空两路管道。
test "zero retention still drains both pipes using caller arena" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cancel: p.Cancellation = .{};
    const r = try run(arena.allocator(), std.testing.io, ctx.root, "printf '%131072s' ''; printf '%131072s' '' >&2", &ctx.env, .{ .output_bytes = 0, .timeout_ms = 1500, .cleanup_timeout_ms = 500 }, &cancel);
    try std.testing.expect(r.stdout.len == 0 and r.stderr.len == 0);
    try std.testing.expectEqual(@as(u64, 131072), r.stdout_bytes);
    try std.testing.expectEqual(@as(u64, 131072), r.stderr_bytes);
    try std.testing.expect(r.truncated and !r.cleanup_failed);
}

// 验证任意切分的 UTF-8 与换行在渲染后保持正确，且不产生终端控制序列。
test "UTF8 and newlines survive arbitrary read splits without terminal escapes" {
    var capture: Capture = .{ .data = try std.testing.allocator.alloc(u8, 128) };
    defer std.testing.allocator.free(capture.data);
    const original = "你好🙂\nline\tend";
    for (0..original.len) |i| capture.add(original[i..][0..1]);
    const rendered = try capture.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(original, rendered);
    try std.testing.expect(!capture.omitted);

    for (1..40) |cap| {
        var clipped: Capture = .{ .data = try std.testing.allocator.alloc(u8, cap) };
        defer std.testing.allocator.free(clipped.data);
        for (0..5) |_| clipped.add(original);
        const output = try clipped.render(std.testing.allocator);
        defer std.testing.allocator.free(output);
        try std.testing.expect(output.len <= cap);
        try std.testing.expect(std.unicode.utf8ValidateSlice(output));
        try std.testing.expect(clipped.omitted);
    }
}

// 验证 cwd_dir 锚定的目录不会跟随被替换的路径。
test "anchored cwd does not follow a replacement path" {
    var ctx = try TestContext.init();
    defer ctx.deinit();
    try ctx.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "marker", .data = "anchored" });
    var cancel = p.Cancellation{};
    var options = test_options;
    options.cwd_dir = ctx.tmp.dir;
    const result = try run(std.testing.allocator, std.testing.io, "/nonexistent-replaced-root", "cat marker", &ctx.env, options, &cancel);
    defer freeResult(result);
    try std.testing.expectEqualStrings("anchored", result.stdout);
    try std.testing.expect(!result.cleanup_failed);
}

// 验证二进制输出被转义，且渲染结果严格不超过字节预算。
test "binary output is escaped and rendered byte budget is strict" {
    var capture: Capture = .{ .data = try std.testing.allocator.alloc(u8, 64) };
    defer std.testing.allocator.free(capture.data);
    capture.add("a\x1b\x00\xff\r\n\\");
    const rendered = try capture.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("a\\x1b\\x00\\xff\\x0d\n\\\\", rendered);

    for (0..17) |cap| {
        var small: Capture = .{ .data = try std.testing.allocator.alloc(u8, cap) };
        defer std.testing.allocator.free(small.data);
        small.add("AB\x1b\xffCDEF\xff\x1bYZ");
        const text = try small.render(std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expect(text.len <= cap);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text));
        for (text) |b| try std.testing.expect(b == '\n' or (b >= 32 and b <= 126));
    }
}
