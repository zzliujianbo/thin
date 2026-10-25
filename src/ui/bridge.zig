//! Single runtime producer / single UI consumer. Bridge must remain at a stable
//! address until worker joined and every popped Item deinitialized. Allocator must
//! support concurrent worker allocation / consumer free. reset/deinit require join.
//! 中文说明：本文件实现运行时（单生产者，工作线程）与 UI（单消费者）之间的有界事件桥。
//! 事件入队时被深拷贝到独立内存中，消费者通过 pop 取得 Item 并负责 deinit 归还预算。

const std = @import("std");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const Io = std.Io;

/// 队列最大条目数（待消费事件的上限）。
pub const queue_capacity = 64;
/// 所有在途事件共享的总字节预算，超出时生产者等待而不是无限增长内存。
pub const data_budget = 256 * 1024;
/// 单个事件文本拷贝的字节上限，超出部分被截断并标记 display_truncated。
pub const item_budget = 64 * 1024;
/// assistant_committed 事件最多拷贝的 Block 数，防止恶意超大数组耗尽预算。
pub const block_limit = 256;

/// 事件拷贝所用的内存类型；按 Block 对齐，便于直接把 Block 数组放在其中。
const Storage = []align(@alignOf(p.Block)) u8;

/// 队列中的一个事件及其独占的拷贝内存。由 pop 交出所有权，调用方必须调用 deinit。
pub const Item = struct {
    /// 已深拷贝到 storage 中的事件，字符串都指向 storage。
    event: r.Event,
    /// 文本是否因预算被截断，UI 可据此提示。
    display_truncated: bool,
    /// Text clipping and a missing block tail are distinct semantic facts.
    /// Incomplete canonical arrays cannot prove absence of tool calls.
    canonical_complete: bool = true,
    /// 本 Item 独占的拷贝内存，deinit 时释放。
    storage: Storage,
    /// 所属的桥，deinit 时用于回收 bytes 与 outstanding 计数。
    owner: *Bridge,

    /// 释放内存并归还预算；每个 Item 只能调用一次。
    pub fn deinit(self: *Item) void {
        const n = self.storage.len;
        // 先在锁外释放内存，只在更新计数时持锁。
        self.owner.allocator.free(self.storage);
        self.owner.lock();
        self.owner.bytes -= n;
        self.owner.outstanding -= 1;
        self.owner.unlock();
        self.* = undefined;
    }
};

// Two bounded passes: measure first, reserve under lock, allocate/copy unlocked.
// Block metadata itself counts against the display budget. Never inspect more
// than block_limit blocks, even for adversarially large canonical arrays.
// 中文：分两遍处理：先测量长度，锁内预留预算，锁外分配并拷贝；Block 元数据也计入预算，且最多检查 block_limit 个 Block。
/// 事件深拷贝器。storage 为 null 时只测量需要的字节数（used），不做拷贝。
const Copy = struct {
    /// 拷贝目标；为 null 表示测量阶段。
    storage: ?Storage = null,
    /// 已占用（测量阶段即为所需）的字节数。
    used: usize = 0,
    /// 是否发生过截断。
    clipped: bool = false,
    canonical_complete: bool = true,

    /// 拷贝一段字符串，超出 item_budget 的部分截断。
    fn text(self: *Copy, src: []const u8) []const u8 {
        var n = @min(src.len, item_budget - self.used);
        // 中文：截断时回退到 UTF-8 码点边界，避免把多字节字符切成两半。
        // Avoid cutting a valid UTF-8 codepoint in half.
        if (n < src.len) {
            while (n > 0 and (src[n] & 0xc0) == 0x80) n -= 1;
            self.clipped = true;
        }
        const start = self.used;
        self.used += n;
        if (self.storage) |buf| {
            @memcpy(buf[start..][0..n], src[0..n]);
            return buf[start..][0..n];
        }
        return "";
    }

    fn field(self: *Copy, src: ?@import("../core/tool_preview.zig").Field) ?@import("../core/tool_preview.zig").Field {
        const value = src orelse return null;
        const before = self.used;
        const copied = self.text(value.text);
        return .{ .text = copied, .truncated = value.truncated or self.used - before < value.text.len };
    }

    /// 深拷贝一个 Block 中的所有字符串字段。
    fn block(self: *Copy, b: p.Block) p.Block {
        return switch (b) {
            .text => |s| .{ .text = self.text(s) },
            .reasoning => |s| .{ .reasoning = self.text(s) },
            .tool_call => |c| .{ .tool_call = .{ .id = self.text(c.id), .name = self.text(c.name), .arguments = self.text(c.arguments), .item_id = if (c.item_id) |s| self.text(s) else null } },
            .tool_result => |v| blk: {
                var c = v;
                c.call_id = self.text(v.call_id);
                c.text = self.text(v.text);
                break :blk .{ .tool_result = c };
            },
        };
    }

    /// 深拷贝事件中的字符串字段；assistant_committed 的 Block 数组最多处理 block_limit 个。
    fn event(self: *Copy, e: r.Event) r.Event {
        return switch (e) {
            .text => |s| .{ .text = self.text(s) },
            // Inbox bounds this at item_budget. Unlike display previews, this
            // is the canonical user message and must be copied in its entirety.
            .user_committed => |v| .{ .user_committed = .{ .id = v.id, .text = self.text(v.text) } },
            .reasoning => |s| .{ .reasoning = self.text(s) },
            .tool_preview => |v| .{ .tool_preview = .{ .index = v.index, .arguments = self.text(v.arguments), .write_file = v.write_file, .argument_bytes = v.argument_bytes } },
            .tool_view => |v| blk: {
                var c = v;
                c.name = self.text(v.name);
                c.fields.path = self.field(v.fields.path);
                c.fields.command = self.field(v.fields.command);
                c.fields.action = self.field(v.fields.action);
                c.fields.topic = self.field(v.fields.topic);
                c.fields.task = self.field(v.fields.task);
                c.fields.id = self.field(v.fields.id);
                break :blk .{ .tool_view = c };
            },
            .permission => |v| .{ .permission = .{ .id = v.id, .tool_name = self.text(v.tool_name), .description = self.text(v.description) } },
            .tool_started => |v| blk: {
                var c = v;
                c.name = self.text(v.name);
                break :blk .{ .tool_started = c };
            },
            .tool_result => |v| blk: {
                var c = v;
                c.name = self.text(v.name);
                c.result.text = self.text(v.result.text);
                break :blk .{ .tool_result = c };
            },
            .assistant_committed => |blocks| blk: {
                const n: usize = @min(blocks.len, block_limit);
                self.canonical_complete = blocks.len == n;
                self.clipped = !self.canonical_complete;
                // 中文：Block 数组本身存放在 storage 开头，此处先按元数据大小计入预算。
                self.used = n * @sizeOf(p.Block);
                // 中文：测量阶段 storage 为 null，dst 为空切片，仅用于计算需求。
                var dst: []p.Block = &.{};
                if (self.storage) |buf| dst = @as([*]p.Block, @ptrCast(buf.ptr))[0..n];
                for (blocks[0..n], 0..) |b, i| {
                    const cloned = self.block(b);
                    if (self.storage != null) dst[i] = cloned;
                }
                break :blk .{ .assistant_committed = dst };
            },
            else => e,
        };
    }
};

/// 单生产者 / 单消费者的有界事件桥。负责队列与字节预算、权限请求的同步，以及任务终态的传递。
pub const Bridge = struct {
    /// 用于拷贝事件内存的分配器。
    allocator: std.mem.Allocator,
    /// 等待时用于 sleep 的 Io 实例。
    io: Io,
    /// 外部取消令牌；close 与 reset 会修改它。
    cancel: *p.Cancellation,

    /// 保护本结构中所有可变字段的互斥锁。
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    /// UI 已断开（close 之后为 true），之后的事件会被拒绝。
    disconnected: bool = false,

    /// 环形队列，有效区间为 [head, head + len) 对 queue_capacity 取模。
    queue: [queue_capacity]Item = undefined,
    /// 环形队列的头下标。
    head: usize = 0,
    /// 队列中当前的条目数。
    len: usize = 0,

    /// 已占用的预算字节数（含预留中的拷贝与已弹出但未 deinit 的 Item）。
    bytes: usize = 0, // includes reserved copies AND popped, still-owned items
    /// 已入队或已弹出但尚未 deinit 的 Item 数量。
    outstanding: usize = 0,
    /// 正在 emit / authorize 中的调用数；reset 与 deinit 要求其为 0。
    active: usize = 0,

    /// 任务的终态结果（finished 事件），由 takeTerminal 取走。
    terminal: ?r.Terminal = null,
    /// 当前等待用户回答的权限请求 ID；同一时刻最多一个。
    pending: ?u64 = null,
    /// 用户对 pending 的决定，null 表示尚未回答。
    answer: ?r.Decision = null,
    /// 见过的最大权限 ID，新请求的 ID 必须严格大于它。
    last_id: ?u64 = null,

    /// 创建桥对象。返回值需要放到稳定地址上使用（见文件头说明）。
    pub fn init(a: std.mem.Allocator, io: Io, cancel: *p.Cancellation) Bridge {
        return .{ .allocator = a, .io = io, .cancel = cancel };
    }

    /// 加锁。pthread 调用失败视为不可恢复错误，直接断言。
    fn lock(self: *Bridge) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.mutex) == .SUCCESS);
    }

    /// 解锁，与 lock 配对。
    fn unlock(self: *Bridge) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.mutex) == .SUCCESS);
    }

    /// 返回运行时使用的 Host 接口，其上下文指向本 Bridge。
    pub fn host(self: *Bridge) r.Host {
        return .{ .context = self, .emit_fn = emit, .authorize_fn = authorize, .rebase_permission_fn = rebasePermissionIds };
    }

    /// 从 Host 的上下文指针还原出 Bridge。
    fn from(ctx: ?*anyopaque) *Bridge {
        return @ptrCast(@alignCast(ctx.?));
    }

    /// 判断是否应当停止：UI 已断开、全局取消，或本次调用的取消令牌被触发。调用方需持锁。
    fn stopped(self: *Bridge, cancel: *const p.Cancellation) bool {
        return self.disconnected or self.cancel.isRequested() or cancel.isRequested();
    }

    /// 让出 2ms，用于队列满、预算不足或等待权限时的轮询。调用方需先解锁。
    fn pause(self: *Bridge) !void {
        try Io.sleep(self.io, .fromMilliseconds(2), .awake);
    }

    /// 结束一次 emit / authorize 调用，与 active 计数配对。
    fn leave(self: *Bridge) void {
        self.lock();
        self.active -= 1;
        self.unlock();
    }

    /// 清除当前权限请求及其答复。调用方需持锁。
    fn clearPermission(self: *Bridge) void {
        self.pending = null;
        self.answer = null;
    }

    /// 运行时的事件入口（工作线程调用）。流程：处理终态 -> 检查取消 -> 校验权限 ID -> 两阶段预留预算并拷贝 -> 入队。
    fn emit(ctx: ?*anyopaque, event: r.Event, cancel: *const p.Cancellation) anyerror!void {
        const self = from(ctx);
        // Canonical injected user text is never a clipped display preview.
        if (event == .user_committed and event.user_committed.text.len > item_budget) return error.InputTooLarge;
        self.lock();
        // 中文：finished 不进入队列，只保存终态，也不占用预算。
        if (event == .finished) {
            self.terminal = event.finished;
            self.clearPermission();
            self.unlock();
            return;
        }

        if (self.stopped(cancel)) {
            self.clearPermission();
            self.unlock();
            return error.Canceled;
        }

        // 中文：权限 ID 必须严格递增且同一时间只允许一个待答请求，防止旧的决定批准新请求。
        if (event == .permission) {
            const id = event.permission.id;
            if (self.pending != null or (self.last_id != null and id <= self.last_id.?)) {
                self.unlock();
                return error.InvalidPermission;
            }
            self.pending = id;
            self.last_id = id;
            self.answer = null;
        }

        self.active += 1;
        self.unlock();
        defer self.leave();
        errdefer if (event == .permission) {
            self.lock();
            self.clearPermission();
            self.unlock();
        };

        // 中文：第一遍只测量需要的字节数，不做分配。
        var measure = Copy{};
        _ = measure.event(event);
        // 中文：预留阶段。队列满或预算不足时短暂让出并重试；预留成功后立即释放锁。
        while (true) {
            self.lock();
            if (self.stopped(cancel)) {
                self.unlock();
                return error.Canceled;
            }
            if (self.len < queue_capacity and measure.used <= data_budget - self.bytes) {
                self.bytes += measure.used;
                self.unlock();
                break;
            }
            self.unlock();
            try self.pause();
        }

        errdefer {
            self.lock();
            self.bytes -= measure.used;
            self.unlock();
        }

        // 中文：第二遍在锁外分配并拷贝，避免分配期间持有互斥锁。
        const storage = try self.allocator.alignedAlloc(u8, .of(p.Block), measure.used);
        errdefer self.allocator.free(storage);
        var copy = Copy{ .storage = storage };
        const owned = copy.event(event);

        self.lock();
        defer self.unlock();
        // 中文：分配期间 UI 可能已断开或被取消，入队前必须再检查一次。
        if (self.stopped(cancel)) return error.Canceled;
        self.queue[(self.head + self.len) % queue_capacity] = .{ .event = owned, .display_truncated = copy.clipped, .canonical_complete = copy.canonical_complete, .storage = storage, .owner = self };
        self.len += 1;
        self.outstanding += 1;
    }

    /// 权限确认入口（工作线程调用）。登记 pending 请求后轮询，直到 UI 调用 decide 作出回答。
    /// 取消令牌已置位且用户尚未表态时返回 `error.Canceled`（工具不执行，也不记成 deny）。
    /// 断开或请求已被替换时仍返回 deny：没有新的用户允许，工具不执行。
    fn authorize(ctx: ?*anyopaque, permission: r.Permission, cancel: *const p.Cancellation) anyerror!r.Decision {
        const self = from(ctx);
        self.lock();
        self.active += 1;
        self.unlock();
        defer self.leave();

        defer {
            self.lock();
            if (self.pending == permission.id) self.clearPermission();
            self.unlock();
        }

        while (true) {
            // Never acquire Inbox while holding Bridge: Core may emit after
            // resolving a lease. A pending steer revokes even a raced answer.
            if (permission.interrupt) |inbox| if (inbox.hasSteering()) {
                self.lock();
                if (self.pending == permission.id) self.clearPermission();
                self.unlock();
                return error.Steered;
            };
            self.lock();
            // Only this request's decision counts. A leftover answer for another
            // id must not be reused, and cancel is not a user deny.
            if (self.pending == permission.id) {
                if (self.answer) |answer| {
                    self.clearPermission();
                    self.unlock();
                    return answer;
                }
                if (self.cancel.isRequested() or cancel.isRequested()) {
                    self.clearPermission();
                    self.unlock();
                    return error.Canceled;
                }
                if (!self.disconnected) {
                    self.unlock();
                    try self.pause();
                    continue;
                }
            }
            self.unlock();
            return .deny;
        }
    }

    /// Drop the permission high-water mark so the runtime can start a new epoch
    /// after u64 exhaustion. Refuses while a request is still pending, so a stale
    /// decision cannot approve the first id of the new epoch.
    fn rebasePermissionIds(ctx: ?*anyopaque) anyerror!void {
        const self = from(ctx);
        self.lock();
        defer self.unlock();
        if (self.pending != null) return error.PermissionPending;
        self.last_id = null;
    }

    /// UI 对权限请求 id 作出决定。仅当 id 与 pending 匹配且尚未回答时返回 true。
    pub fn decide(self: *Bridge, id: u64, decision: r.Decision) bool {
        self.lock();
        defer self.unlock();
        // 已停止时清除请求。取消令牌使 authorize 返回 Canceled；仅断开且未取消时才是 deny。
        if (self.stopped(self.cancel)) {
            self.clearPermission();
            return false;
        }

        if (self.pending != id or self.answer != null) return false;
        self.answer = decision;
        return true;
    }

    /// 从队列头取出一个 Item，所有权转移给调用方（必须最终调用 deinit）。队列为空时返回 null。
    pub fn pop(self: *Bridge) ?Item {
        self.lock();
        defer self.unlock();
        if (self.len == 0) return null;
        const item = self.queue[self.head];
        self.head = (self.head + 1) % queue_capacity;
        self.len -= 1;
        return item;
    }

    /// 断开 UI：触发取消、标记 disconnected 并清除权限请求。
    pub fn close(self: *Bridge) void {
        self.lock();
        defer self.unlock();
        // One critical section linearizes disconnect with decision/enqueue.
        // 中文：在同一临界区内完成断开，使其与 decide / 入队的先后顺序保持一致。
        self.cancel.cancel();
        self.disconnected = true;
        self.clearPermission();
    }

    /// 取走并清空终态结果；尚无终态时返回 null。
    pub fn takeTerminal(self: *Bridge) ?r.Terminal {
        self.lock();
        defer self.unlock();
        const terminal = self.terminal;
        self.terminal = null;
        return terminal;
    }

    /// 复位桥以供下一个任务复用。若仍有活动调用或未释放的 Item，返回 error.Busy。
    pub fn reset(self: *Bridge) !void {
        self.lock();
        defer self.unlock();
        if (self.active != 0 or self.len != 0 or self.outstanding != 0 or self.bytes != 0) return error.Busy;

        self.clearPermission();
        // Keep the ID high-water mark: stale prior-task decisions cannot approve
        // a reused ID. Use a fresh Bridge when replacing the Runtime instance.
        // 中文：保留 last_id 高水位，避免旧任务的决定批准复用了 ID 的新请求；更换 Runtime 时应新建 Bridge。
        self.terminal = null;
        self.disconnected = false;
        self.cancel.requested.store(false, .release);
        self.head = 0;
    }

    /// 关闭并释放桥。调用前工作线程必须已 join；会逐个弹出并 deinit 残留的 Item。
    pub fn deinit(self: *Bridge) void {
        self.close();
        std.debug.assert(self.active == 0);

        // 中文：残留 Item 必须逐个释放，否则预算与分配内存都会泄漏。
        while (self.pop()) |item_| {
            var item = item_;
            item.deinit();
        }

        std.debug.assert(self.outstanding == 0 and self.bytes == 0);
        std.debug.assert(std.c.pthread_mutex_destroy(&self.mutex) == .SUCCESS);
        self.* = undefined;
    }
};

test "user committed copy owns the entire bounded text including the last byte" {
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var original: [item_budget]u8 = @splat('x');
    original[item_budget - 1] = 'Z';
    const host_ = bridge.host();
    try host_.emit_fn(host_.context, .{ .user_committed = .{ .id = 7, .text = &original } }, &cancel);
    @memset(&original, 'q');
    var item = bridge.pop().?;
    defer item.deinit();
    try std.testing.expectEqual(@as(usize, item_budget), item.event.user_committed.text.len);
    try std.testing.expectEqual(@as(u8, 'x'), item.event.user_committed.text[0]);
    try std.testing.expectEqual(@as(u8, 'Z'), item.event.user_committed.text[item_budget - 1]);
    try std.testing.expect(!item.display_truncated);
}

test "steering interrupts matching pending permission outside bridge lock without denying" {
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var inbox: r.Inbox = .{};
    defer inbox.deinit();
    inbox.beginRun();
    _ = try inbox.enqueue(std.testing.allocator, .steering, "new instruction");
    const host_ = bridge.host();
    try host_.emit_fn(host_.context, .{ .permission = .{ .id = 8, .tool_name = "bash", .description = "not started" } }, &cancel);
    try std.testing.expectError(error.Steered, host_.authorize_fn(host_.context, .{
        .id = 8,
        .tool_name = "bash",
        .description = "not started",
        .interrupt = &inbox,
    }, &cancel));
    try std.testing.expect(bridge.pending == null and bridge.answer == null);
    try std.testing.expect(!cancel.isRequested());
    try std.testing.expectEqual(@as(usize, 1), inbox.snapshot().steering);
}

// Regression: tool_view.task/id snapshots stayed borrowed from the producer's
// JSON extractor, so encoding them after the producer moved on read freed
// memory (worker segfault on the second background-management round). All six
// snapshot fields must be owned by the Item, not merely byte-equal.
test "tool view copy owns all six snapshot fields after producer storage is freed" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(t.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    const host_ = bridge.host();

    const expected = [_][]const u8{ "path.txt", "run.sh", "open", "topic-x", "delegate summary", "job-7" };
    var borrowed: [expected.len][]u8 = undefined;
    {
        // Producer-side arena: released and overwritten before the consumer pops.
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        for (expected, 0..) |value, i| borrowed[i] = try arena.allocator().dupe(u8, value);
        try host_.emit_fn(host_.context, .{ .tool_view = .{
            .key = .{ .generation = 5, .index = 2 },
            .name = "background",
            .fields = .{
                .path = .{ .text = borrowed[0] },
                .command = .{ .text = borrowed[1], .truncated = true },
                .action = .{ .text = borrowed[2] },
                .topic = .{ .text = borrowed[3] },
                .task = .{ .text = borrowed[4] },
                .id = .{ .text = borrowed[5], .truncated = true },
            },
            .ready = true,
        } }, &cancel);
        for (borrowed) |slice| @memset(slice, 'x');
    }

    var item = bridge.pop().?;
    defer item.deinit();
    const view = item.event.tool_view;
    try t.expect(!item.display_truncated);
    try t.expectEqualStrings("background", view.name);
    inline for (.{ "path", "command", "action", "topic", "task", "id" }, 0..) |name, i| {
        const text = @field(view.fields, name).?.text;
        try t.expectEqualStrings(expected[i], text);
        // Ownership, not only equal bytes: every non-empty text lives in storage.
        const lo = @intFromPtr(item.storage.ptr);
        try t.expect(@intFromPtr(text.ptr) >= lo);
        try t.expect(@intFromPtr(text.ptr) + text.len <= lo + item.storage.len);
    }
    // Producer-side truncation flags survive; no clipping happened here.
    try t.expect(view.fields.command.?.truncated);
    try t.expect(view.fields.id.?.truncated);
    try t.expect(!view.fields.task.?.truncated);
}

// The shared measure/copy budget must account for task and stop on a codepoint
// boundary; UTF-8 safety here mirrors the existing field-cap coverage.
test "task snapshot clipping stops on a utf8 boundary inside the shared item cap" {
    const t = std.testing;
    var cancel: p.Cancellation = .{};
    var bridge = Bridge.init(t.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    const host_ = bridge.host();

    const huge = try t.allocator.alloc(u8, item_budget + 8);
    defer t.allocator.free(huge);
    var i: usize = 0;
    while (i + 3 <= huge.len) : (i += 3) @memcpy(huge[i..][0..3], "\xe5\xad\x97");
    try host_.emit_fn(host_.context, .{ .tool_view = .{
        .key = .{ .generation = 1, .index = 0 },
        .name = "",
        .fields = .{ .task = .{ .text = huge } },
    } }, &cancel);

    var item = bridge.pop().?;
    defer item.deinit();
    const task = item.event.tool_view.fields.task.?;
    try t.expectEqual(item_budget - 1, task.text.len);
    try t.expectEqual(item_budget - 1, item.storage.len);
    try t.expect(task.truncated and item.display_truncated);
    try t.expect(std.unicode.utf8ValidateSlice(task.text));
}
