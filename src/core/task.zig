//! 任务层：把一次 Runtime 运行封装为可在后台执行的 Job，并提供完成状态与结果读取。
//! 调用方通过 Job.done 判断是否已结束，不得在未完成时读取结果。

const std = @import("std");
const p = @import("protocol.zig");
const r = @import("runtime.zig");

/// Host-owned worker; caller keeps Job and prompt alive until future is joined.
/// The completion flag is independent of any display queue and set on all exits.
/// 中文：Job 由宿主持有；在 worker 结束（join）之前，调用方必须保证 Job 与 prompt 仍然有效。
/// 完成标志独立于显示队列，并且在所有退出路径上都会被设置。
pub const Job = struct {
    /// 执行本次任务的 Runtime，由宿主持有。
    runtime: *r.Runtime,
    /// 取消通道，与 Runtime 共享。
    cancel: *p.Cancellation,
    /// 用户输入，调用方需保证其生命周期覆盖整个任务。
    prompt: []const u8,
    /// 任务是否已结束（成功或失败均为 true）；读写使用 release/acquire 配对。
    done: std.atomic.Value(bool) = .init(false),
    /// 成功时的运行结果；失败或未完成时为 null。
    terminal: ?r.Terminal = null,
    /// 运行失败时记录的错误。
    failure: ?anyerror = null,

    /// worker 线程入口：执行 Runtime 并记录结果或错误。
    pub fn run(self: *Job) void {
        // 无论成功还是出错，都必须设置 done，否则 result() 会一直返回 TaskStillRunning。
        defer self.done.store(true, .release);
        self.terminal = self.runtime.run(self.prompt, self.cancel) catch |err| {
            // 错误被保存到 failure，由 result() 在主线程中取出，不在 worker 中抛出。
            self.failure = err;
            return;
        };
    }

    /// 非阻塞地读取结果：任务未完成时返回 TaskStillRunning，不会等待。
    pub fn result(self: *Job) !r.Terminal {
        if (!self.done.load(.acquire)) return error.TaskStillRunning;
        if (self.failure) |err| return err;
        // 理论上 done 为 true 且无 failure 时 terminal 应已设置；若为空则视为异常。
        return self.terminal orelse error.MissingTerminal;
    }
};
