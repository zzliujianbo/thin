//! Process-local graceful interruption; handlers only perform a lock-free store.
//! 中文：进程内的优雅中断。信号处理函数只记录信号编号，由主循环轮询 signal() 后自行决定退出流程。

const std = @import("std");
const c = std.c;

/// 最近收到的信号编号，0 表示没有待处理的中断。用原子变量在异步信号上下文与主线程之间传递。
var received = std.atomic.Value(u8).init(0);

/// 需要捕获的信号：INT(Ctrl-C)、TERM、HUP（终端断开）、QUIT(Ctrl-\)。
const signals = [_]c.SIG{ .INT, .TERM, .HUP, .QUIT };

/// 信号处理函数：只允许 async-signal-safe 操作，因此这里仅做一次原子存储，不分配内存、不加锁、不打印。
fn handler(sig: c.SIG) callconv(.c) void {
    // release 语义保证主线程用 acquire 读取时能看到该编号。
    received.store(@intCast(@backingInt(sig)), .release);
}

/// 读取最近收到的信号编号；0 表示没有待处理的中断。
pub fn signal() u8 {
    return received.load(.acquire);
}

/// 清除已记录的信号编号。
pub fn clear() void {
    received.store(0, .release);
}

/// 信号守卫：install 时替换 signals 中各信号的处理函数并保存原 action，deinit 时恢复。
pub const Guard = struct {
    /// 每个信号原来的 sigaction，deinit 时用于恢复。
    originals: [signals.len]c.Sigaction,
    /// 已成功安装的信号数量；deinit 只恢复这些，避免动到未修改的信号。
    installed: usize = 0,

    /// 安装信号处理函数。任一步失败时 errdefer 回滚已安装的部分。
    pub fn install() !Guard {
        var self: Guard = .{ .originals = undefined };

        // 失败路径会调用 deinit，按 installed 计数逐个恢复已修改的信号。
        errdefer self.deinit();

        // 清空旧的中断记录，避免上一次残留的信号被误判为本次中断。
        clear();

        // 不设置 SA_RESTART：中断后阻塞的系统调用返回 EINTR，让主循环能及时检查中断。
        var action = std.mem.zeroes(c.Sigaction);
        action.handler = .{ .handler = handler };

        // handler 执行期间不额外屏蔽其它信号（mask 为空）。
        if (c.sigemptyset(&action.mask) != 0) return error.SignalSetupFailed;

        // 逐个安装，originals[i] 保存旧 action；installed 随成功安装递增。
        for (signals, 0..) |sig, i| {
            if (c.sigaction(sig, &action, &self.originals[i]) != 0) return error.SignalSetupFailed;
            self.installed += 1;
        }
        return self;
    }

    /// 按安装的逆序恢复原处理函数；重复调用是安全的（计数归零后不再执行）。
    pub fn deinit(self: *Guard) void {
        // 先递减再使用索引，恢复的正是最后一个成功安装的信号。
        while (self.installed > 0) {
            self.installed -= 1;
            _ = c.sigaction(signals[self.installed], &self.originals[self.installed], null);
        }
    }
};
