//! 探针测试的公共辅助模块：统一的 Io 别名、测试分配器、跨线程标志、带超时的等待、环境变量读取和管道读取。

const std = @import("std");

// 标准库 Io 的别名，便于各探针书写。
pub const Io = std.Io;
// 测试分配器：会检测内存泄漏，任何未释放的内存都会让测试失败。
pub const alloc = std.testing.allocator;

/// 原子布尔标志，用于在不同任务（线程）之间发出“已就绪”或“已完成”信号。
pub const Flag = std.atomic.Value(bool);

/// 创建一个线程化的 Io 后端，最多允许 8 个并发任务。
pub fn backend() Io.Threaded {
    return Io.Threaded.init(alloc, .{ .concurrent_limit = .limited(8) });
}

/// 从测试进程的环境变量中读取 name；不存在时返回 error.MissingProbeEnvironment。
pub fn env(name: []const u8) ![]const u8 {
    return std.testing.environ.getPosix(name) orelse error.MissingProbeEnvironment;
}

/// 每 2 毫秒轮询一次 flag，直到其变为 true；超过 timeout_ms 毫秒则返回 error.ProbeTimedOut。
pub fn waitFlag(io: Io, flag: *Flag, timeout_ms: i64) !void {
    const start = Io.Clock.awake.now(io);
    while (!flag.load(.acquire)) {
        if (start.untilNow(io, .awake).toMilliseconds() >= timeout_ms)
            return error.ProbeTimedOut;
        try Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

/// 读取文件（通常是管道）直到 EOF，最多读取 1 MiB，结果由调用者负责释放。
pub fn readPipe(io: Io, file: Io.File) ![]u8 {
    var buffer: [1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(alloc, .limited(1024 * 1024));
}
