//! UI bridge 的单元测试根文件。
//! 覆盖有界事件队列、数据预算、权限决策、取消、关闭与内存分配失败时的回滚。
//! 测试通过 Io.Threaded 后端启动真实并发 worker，用 waitActive 等待 worker 阻塞在 emit 上。

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

// 写满队列：发送 queue_capacity 个非可靠事件，使下一次可靠发送必须等待。
fn fill(bridge: *b.Bridge) !void {
    for (0..b.queue_capacity) |_| try send(bridge, .{ .state = .calling_model });
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

// 发送一个可靠的 tool_result；队列满时它会阻塞，直到取消、关闭或消费者腾出空间。
fn blockedEmit(bridge: *b.Bridge) !void {
    try send(bridge, .{ .tool_result = .{ .id = 1, .name = "result", .result = .{ .text = "reliable" } } });
}

// 验证 bridge 深拷贝了所有借用的载荷：源 arena 释放并覆写后，出队数据仍正确。
test "bridge owns every borrowed payload after source arena is freed" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();

    {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // 所有借用字段都指向同一段 arena 内存，便于统一验证拷贝是否完整。
        const s = try a.dupe(u8, "owned");
        const blocks = try a.alloc(p.Block, 4);
        blocks[0] = .{ .text = s };
        blocks[1] = .{ .reasoning = s };
        blocks[2] = .{ .tool_call = .{ .id = s, .name = s, .arguments = s, .item_id = s } };
        blocks[3] = .{ .tool_result = .{ .call_id = s, .text = s, .truncated = true } };
        try send(&bridge, .{ .assistant_committed = blocks });
        try send(&bridge, .{ .text = s });
        try send(&bridge, .{ .reasoning = s });
        try send(&bridge, .{ .tool_preview = .{ .index = 3, .arguments = s } });
        try send(&bridge, .{ .permission = .{ .id = 1, .tool_name = s, .description = s } });
        try send(&bridge, .{ .tool_started = .{ .id = 1, .name = s } });
        try send(&bridge, .{ .tool_result = .{ .id = 1, .name = s, .result = .{ .text = s, .cleanup_failed = true } } });
        @memset(s, 'x'); // deterministic proof of no borrowing, as well as free
    }

    var item = bridge.pop().?;
    try t.expect(!item.display_truncated);
    const blocks = item.event.assistant_committed;
    try t.expectEqualStrings("owned", blocks[0].text);
    try t.expectEqualStrings("owned", blocks[1].reasoning);
    try t.expectEqualStrings("owned", blocks[2].tool_call.id);
    try t.expectEqualStrings("owned", blocks[2].tool_call.name);
    try t.expectEqualStrings("owned", blocks[2].tool_call.arguments);
    try t.expectEqualStrings("owned", blocks[2].tool_call.item_id.?);
    try t.expectEqualStrings("owned", blocks[3].tool_result.call_id);
    try t.expectEqualStrings("owned", blocks[3].tool_result.text);
    try t.expect(blocks[3].tool_result.truncated);
    item.deinit();
    item = bridge.pop().?;
    try t.expectEqualStrings("owned", item.event.text);
    item.deinit();
    item = bridge.pop().?;
    try t.expectEqualStrings("owned", item.event.reasoning);
    item.deinit();
    item = bridge.pop().?;
    try t.expectEqualStrings("owned", item.event.tool_preview.arguments);
    item.deinit();
    item = bridge.pop().?;
    try t.expectEqualStrings("owned", item.event.permission.tool_name);
    try t.expectEqualStrings("owned", item.event.permission.description);
    item.deinit();
    item = bridge.pop().?;
    try t.expectEqualStrings("owned", item.event.tool_started.name);
    item.deinit();
    item = bridge.pop().?;
    try t.expectEqualStrings("owned", item.event.tool_result.name);
    try t.expectEqualStrings("owned", item.event.tool_result.result.text);
    try t.expect(item.event.tool_result.result.cleanup_failed);
    item.deinit();
}

// 队列满时，独立的取消请求应使阻塞的可靠生产者返回 Canceled，且队列长度不变。
test "full queue independent cancellation unblocks reliable result producer" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    try fill(&bridge);
    var worker = try Io.concurrent(bridge.io, blockedEmit, .{&bridge});
    defer worker.cancel(bridge.io) catch {};
    try waitActive(&bridge);

    cancel.cancel();
    try t.expectError(error.Canceled, worker.await(bridge.io));
    try t.expectEqual(b.queue_capacity, bridge.len);
}

// 队列满时 close 应取消 worker；终止事件 finished 不经过队列，且只能被取走一次。
test "full queue close unblocks and terminal bypasses cancellation and queue" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    try fill(&bridge);
    var worker = try Io.concurrent(bridge.io, blockedEmit, .{&bridge});
    defer worker.cancel(bridge.io) catch {};
    try waitActive(&bridge);

    bridge.close();
    try t.expect(cancel.isRequested());
    try t.expectError(error.Canceled, worker.await(bridge.io));
    try send(&bridge, .{ .finished = .{ .status = .canceled, .detail = error.Canceled } });
    try t.expectEqual(r.Status.canceled, bridge.takeTerminal().?.status);
    try t.expect(bridge.takeTerminal() == null);
    try t.expectEqual(b.queue_capacity, bridge.len);
}

// 消费者弹出一项后，阻塞的可靠 tool_result 应能入队，并保持 FIFO 顺序。
test "reliable tool result waits then queues when consumer makes room" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    try fill(&bridge);
    var worker = try Io.concurrent(bridge.io, blockedEmit, .{&bridge});
    defer worker.cancel(bridge.io) catch {};
    try waitActive(&bridge);

    var first = bridge.pop().?;
    first.deinit();
    try worker.await(bridge.io);
    for (0..b.queue_capacity - 1) |_| {
        var item = bridge.pop().?;
        item.deinit();
    }
    var result = bridge.pop().?;
    defer result.deinit();
    try t.expectEqualStrings("reliable", result.event.tool_result.result.text);
}

// 权限决策：允许提前决定，拒绝错误、过期或重复的 ID；reset 会清除信任状态。
test "permission accepts early decision, rejects wrong stale and duplicate IDs; reset removes trust" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    try t.expect(!bridge.decide(1, .trust_process));

    try send(&bridge, .{ .permission = .{ .id = 1, .tool_name = "x", .description = "y" } });
    try t.expect(!bridge.decide(2, .allow_once));
    try t.expect(bridge.decide(1, .trust_process));
    try t.expect(!bridge.decide(1, .deny));
    try t.expectEqual(r.Decision.deny, try auth(&bridge, 2));
    try t.expectEqual(r.Decision.trust_process, try auth(&bridge, 1));
    try t.expect(!bridge.decide(1, .allow_once));
    try t.expectEqual(r.Decision.deny, try auth(&bridge, 1));

    // 仍有未释放的队列条目时 reset 必须返回 Busy；先排空并关闭后才能重置。
    try t.expectError(error.Busy, bridge.reset());
    drain(&bridge);
    bridge.close();
    try bridge.reset();
    try t.expect(!cancel.isRequested());
    try t.expect(!bridge.decide(1, .trust_process));
    try t.expectError(error.InvalidPermission, send(&bridge, .{ .permission = .{ .id = 1, .tool_name = "x", .description = "y" } }));
    try send(&bridge, .{ .permission = .{ .id = 2, .tool_name = "x", .description = "y" } });
    try t.expect(!bridge.decide(1, .trust_process));
    try t.expect(bridge.decide(2, .deny));
    try t.expectEqual(r.Decision.deny, try auth(&bridge, 2));
    drain(&bridge);

    try send(&bridge, .{ .permission = .{ .id = 3, .tool_name = "x", .description = "y" } });
    try t.expect(bridge.decide(3, .trust_process));
    drain(&bridge);
    try bridge.reset();
    try t.expectEqual(r.Decision.deny, try auth(&bridge, 3));
    try send(&bridge, .{ .permission = .{ .id = 4, .tool_name = "x", .description = "y" } });
    try t.expect(bridge.decide(4, .deny));
    try t.expectEqual(r.Decision.deny, try auth(&bridge, 4));
}

// 权限在入队前就已安装，取消正在等待权限的 worker 后应清空 pending 和 answer。
test "permission installed before enqueue; cancel while awaiting permission clears it" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    try fill(&bridge);

    const Emit = struct {
        fn run(br: *b.Bridge) !void {
            try send(br, .{ .permission = .{ .id = 7, .tool_name = "x", .description = "y" } });
        }
    };
    var emitter = try Io.concurrent(bridge.io, Emit.run, .{&bridge});
    defer emitter.cancel(bridge.io) catch {};
    try waitActive(&bridge);
    try t.expect(bridge.decide(7, .allow_once));
    var first = bridge.pop().?;
    first.deinit();
    try emitter.await(bridge.io);
    try t.expectEqual(r.Decision.allow_once, try auth(&bridge, 7));
    drain(&bridge);

    try send(&bridge, .{ .permission = .{ .id = 8, .tool_name = "x", .description = "y" } });
    var worker = try Io.concurrent(bridge.io, auth, .{ &bridge, @as(u64, 8) });
    defer _ = worker.cancel(bridge.io) catch .deny;
    try waitActive(&bridge);

    cancel.cancel();
    try t.expectEqual(r.Decision.deny, try worker.await(bridge.io));
    try t.expect(!bridge.decide(8, .trust_process));
    try t.expect(bridge.pending == null and bridge.answer == null);
}

// 显示层裁剪：超长文本被截断，但 is_error、truncated 等执行标志保持原样，元数据长度有上限。
test "bounded display clipping preserves execution flags and bounds canonical metadata" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();
    const huge = try t.allocator.alloc(u8, b.item_budget * 2);
    defer t.allocator.free(huge);
    @memset(huge, 'a');

    try send(&bridge, .{ .tool_result = .{ .id = 1, .name = "name", .result = .{ .text = huge, .is_error = true, .truncated = false } } });
    var item = bridge.pop().?;
    try t.expect(item.display_truncated);
    try t.expect(item.storage.len <= b.item_budget);
    try t.expect(!item.event.tool_result.result.truncated);
    try t.expect(item.event.tool_result.result.is_error);

    // 已弹出但未 deinit 的条目仍计入占用，因此 reset 返回 Busy。
    try t.expectError(error.Busy, bridge.reset()); // popped ownership counts
    item.deinit();

    try send(&bridge, .{ .tool_preview = .{ .index = 0, .arguments = huge } });
    item = bridge.pop().?;
    try t.expect(item.display_truncated);
    try t.expectEqual(b.item_budget, item.event.tool_preview.arguments.len);
    item.deinit();

    const blocks = try t.allocator.alloc(p.Block, 10000);
    defer t.allocator.free(blocks);
    @memset(blocks, .{ .text = "" });
    try send(&bridge, .{ .assistant_committed = blocks });
    item = bridge.pop().?;
    try t.expect(item.display_truncated);
    try t.expectEqual(b.block_limit, item.event.assistant_committed.len);
    try t.expect(item.storage.len <= b.item_budget);
    item.deinit();
    try bridge.reset();
}

// 分配失败时回滚预留的字节与权限状态；终止事件不需要分配，仍能成功送达。
test "allocation failure rolls back reservation and permission; terminal needs no allocation" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var buffer: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var bridge = b.Bridge.init(fixed.allocator(), env.backend.io(), &cancel);
    defer bridge.deinit();

    try t.expectError(error.OutOfMemory, send(&bridge, .{ .permission = .{ .id = 1, .tool_name = "tool", .description = "description" } }));
    try t.expectEqual(@as(usize, 0), bridge.bytes);
    try t.expect(bridge.pending == null and bridge.answer == null);
    try t.expect(!bridge.decide(1, .trust_process));
    try fill(&bridge);

    try send(&bridge, .{ .finished = .{ .status = .failed, .detail = error.OutOfMemory } });
    try t.expectEqual(r.Status.failed, bridge.takeTerminal().?.status);
    try t.expectEqual(b.queue_capacity, bridge.len);
}

// 总预算包含已弹出但未释放的条目；释放这些条目后，阻塞的生产者才能继续并回收字节。
test "total budget includes popped items; freeing ownership releases producer" {
    var env = Env.init();
    defer env.deinit();
    var cancel = p.Cancellation{};
    var bridge = b.Bridge.init(t.allocator, env.backend.io(), &cancel);
    defer bridge.deinit();

    const text = try t.allocator.alloc(u8, b.item_budget);
    defer t.allocator.free(text);
    @memset(text, 'a');

    for (0..b.data_budget / b.item_budget) |_| try send(&bridge, .{ .text = text });

    var held = bridge.pop().?;
    var worker = try Io.concurrent(bridge.io, blockedEmit, .{&bridge});
    defer worker.cancel(bridge.io) catch {};
    try waitActive(&bridge);
    try t.expectEqual(b.data_budget, bridge.bytes);
    held.deinit();
    try worker.await(bridge.io);

    try t.expect(bridge.bytes <= b.data_budget);
    drain(&bridge);
    try t.expectEqual(@as(usize, 0), bridge.bytes);
}
