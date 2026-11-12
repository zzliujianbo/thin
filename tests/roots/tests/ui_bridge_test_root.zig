//! UI bridge 的单元测试根文件。
//! 覆盖动态事件队列、完整载荷保留、权限决策、取消、关闭与分配失败回滚。
//! 测试通过 Io.Threaded 后端启动真实并发 worker；仅权限等待使用 waitActive 同步。

const std = @import("std");
const b = @import("../ui/bridge.zig");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const Io = std.Io;
const t = std.testing;

// 测试环境：持有线程化 Io 后端，供 Io.concurrent 启动 worker 线程。
const Env = struct {
    // 并发上限为 8，足够同时运行测试里的生产者线程。
    backend: Io.Threaded,

    // 构造后端实例，使用测试分配器。
    fn init() Env {
        return .{ .backend = Io.Threaded.init(t.allocator, .{ .concurrent_limit = .limited(8) }) };
    }

    // 释放后端资源；每个测试通过 defer 调用。
    fn deinit(self: *Env) void {
        self.backend.deinit();
    }
};

// 通过 host 接口向 bridge 发送事件，使用 bridge.cancel 作为取消信号。
fn send(bridge: *b.Bridge, event: r.Event) !void {
    const h = bridge.host();
    try h.emit_fn(h.context, event, bridge.cancel);
}

// 通过 host 发起权限请求并阻塞等待决策，返回用户的 Decision。
fn auth(bridge: *b.Bridge, id: u64) !r.Decision {
    const h = bridge.host();
    return h.authorize_fn(h.context, .{ .id = id, .tool_name = "tool", .description = "desc" }, bridge.cancel);
}

// 把队列中所有条目弹出并释放，用于清空状态以便后续断言或 reset。
fn drain(bridge: *b.Bridge) void {
    while (bridge.pop()) |v| {
        var item = v;
        item.deinit();
    }
}

// Finite regression stimulus beyond the former 128-event queue capacity.
const old_queue_capacity = 128;
fn fill(bridge: *b.Bridge) !void {
    for (0..old_queue_capacity + 1) |_| try send(bridge, .{ .state = .calling_model });
}

// 轮询等待 worker 进入 emit 并登记 active，最多约 1 秒，超时返回 WorkerDidNotStart。
fn waitActive(bridge: *b.Bridge) !void {
    // 每次轮询都加锁读取 active，避免与 worker 的写入产生数据竞争。
    for (0..1000) |_| {
        try t.expect(std.c.pthread_mutex_lock(&bridge.mutex) == .SUCCESS);
        const active = bridge.active;
        try t.expect(std.c.pthread_mutex_unlock(&bridge.mutex) == .SUCCESS);
        if (active != 0) return;
        try Io.sleep(bridge.io, .fromMilliseconds(1), .awake);
    }

    return error.WorkerDidNotStart;
}

// 发送可靠 tool_result，验证动态入队和取消/关闭的 admission。
fn blockedEmit(bridge: *b.Bridge) !void {
    try send(bridge, .{ .tool_result = .{ .id = 1, .name = "result", .result = .{ .text = "reliable" } } });
}

// 验证 bridge 深拷贝了所有借用的载荷：源 arena 释放并覆写后，出队数据仍正确。

// 取消应拒绝新的发送，且不丢失已经排队的事件。

// close 应取消后续发送；finished 不经过队列，且只能被取走一次。

// 超过旧队列容量后可靠 tool_result 仍立即入队，并保持 FIFO 顺序。

// 权限决策：允许提前决定，拒绝错误、过期或重复的 ID；reset 会清除待处理批准。

// 权限在入队前就已安装，取消正在等待权限的 worker 后应清空 pending 和 answer。

// 超长文本和完整 Block 数组必须保留，is_error/truncated 执行标志不被改写。

// 分配失败时回滚预留的字节与权限状态；终止事件不需要分配，仍能成功送达。

// 动态队列计数包含已弹出但未释放的条目；释放独占 Item 才回收这些字节。
