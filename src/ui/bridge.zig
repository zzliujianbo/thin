//! Single runtime producer / single UI consumer. Bridge must remain at a stable
//! address until worker joined and every popped Item deinitialized. Allocator must
//! support concurrent worker allocation / consumer free. reset/deinit require join.
//! 中文说明：本文件实现运行时（单生产者，工作线程）与 UI（单消费者）之间的有界事件桥。
//! 事件入队时被深拷贝到独立内存中，消费者通过 pop 取得 Item 并负责 deinit 归还预算。

const std = @import("std");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const Io = std.Io;

/// Streaming chunk size, not a limit on canonical event contents.
pub const item_budget = 64 * 1024;

/// 事件拷贝所用的内存类型；按 Block 对齐，便于直接把 Block 数组放在其中。
const Storage = []align(@alignOf(p.Block)) u8;

/// 队列中的一个事件及其独占的拷贝内存。由 pop 交出所有权，调用方必须调用 deinit。
pub const Item = struct {
    /// 已深拷贝到 storage 中的事件，字符串都指向 storage。
    event: r.Event,
    /// 显示副本是否被裁剪，UI 可据此提示；不是容量预算。
    display_truncated: bool,
    /// Text clipping and a missing block tail are distinct semantic facts.
    /// Incomplete canonical arrays cannot prove absence of tool calls.
    canonical_complete: bool = true,
    /// 本 Item 独占的拷贝内存，deinit 时释放。
    storage: Storage,
    /// 所属的桥，deinit 时用于回收 bytes 与 outstanding 计数。
    owner: *Bridge,

    /// 释放内存并归还有关统计；每个 Item 只能调用一次。
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

// Two passes: measure, then allocate and copy the complete event.
/// 事件深拷贝器。storage 为 null 时只测量需要的字节数（used），不做拷贝。
const Copy = struct {
    /// 拷贝目标；为 null 表示测量阶段。
    storage: ?Storage = null,
    /// 已占用（测量阶段即为所需）的字节数。
    used: usize = 0,
    /// 是否发生过截断。
    clipped: bool = false,
    canonical_complete: bool = true,

    /// Copy the complete string.
    fn text(self: *Copy, src: []const u8) []const u8 {
        const n = src.len;
        const start = self.used;
        self.used += n;
        if (self.storage) |buf| {
            @memcpy(buf[start..][0..n], src[0..n]);
            return buf[start..][0..n];
        }
        return "";
    }

    /// Copy at most `max` bytes, backing off to a UTF-8 boundary. This is a
    /// display projection only; the Runtime keeps the complete result.
    fn textBounded(self: *Copy, src: []const u8, max: usize) []const u8 {
        var n = @min(src.len, max);
        if (n < src.len) {
            while (n > 0 and (src[n] & 0xc0) == 0x80) n -= 1;
            self.clipped = true;
        }
        return self.text(src[0..n]);
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
                c.text = self.textBounded(v.text, item_budget);
                break :blk .{ .tool_result = c };
            },
        };
    }

    /// Deep-copy every event field and canonical block.
    fn event(self: *Copy, e: r.Event) r.Event {
        return switch (e) {
            .text => |s| .{ .text = self.text(s) },
            // This is canonical user content, not a display preview.
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
                if (v.subagent_progress) |progress_text| c.subagent_progress = self.text(progress_text);
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
                // Local command output is rendered verbatim and may carry the
                // exit tail; clip only model tool results, which the UI shows
                // as captions. The Runtime keeps the complete result either way.
                c.result.text = if (v.local) self.text(v.result.text) else self.textBounded(v.result.text, item_budget);
                break :blk .{ .tool_result = c };
            },
            .assistant_committed => |blocks| blk: {
                const n = blocks.len;
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

/// 单个正文切片的最大 UTF-8 安全长度：不超过 limit，且不切断多字节码点。
/// 返回 0 仅当 src 为空（或 limit 为 0）；非空 src 且 limit > 0 时至少返回 1，
/// 因此调用方的逐段循环一定会前进。
fn chunkLen(src: []const u8, limit: usize) usize {
    const n = @min(src.len, limit);
    if (n == src.len or n == 0) return n;
    // 中文：结尾落在续字节上时回退到码点起点，让该码点整体留在下一片。
    var cut = n;
    while (cut > 0 and (src[cut] & 0xc0) == 0x80) cut -= 1;
    // 中文：极端非法字节串（整片都是续字节）无法对齐；退回原长度，仍保证不丢字节。
    return if (cut == 0) n else cut;
}

/// 单生产者 / 单消费者的有界事件桥。负责队列与字节预算、权限请求的同步，以及任务终态的传递。
pub const Bridge = struct {
    /// 用于拷贝事件内存的分配器。
    allocator: std.mem.Allocator,
    /// 等待时用于 sleep 的 Io 实例。
    io: Io,
    /// 外部取消令牌；close 与 reset 会修改它。
    cancel: *p.Cancellation,
    /// Optional coalescing owner notification. Install before producers start;
    /// keep context alive until all producers join. Never a source of state.
    notification: ?struct { context: *anyopaque, notify_fn: *const fn (*anyopaque) void } = null,

    /// 保护本结构中所有可变字段的互斥锁。
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    /// UI 已断开（close 之后为 true），之后的事件会被拒绝。
    disconnected: bool = false,

    queue: std.ArrayList(Item) = .empty,
    /// Only queue.items[head..] owns live items; the prefix has been popped.
    head: usize = 0,
    /// Current queued count, exposed to the existing frontend under the lock.
    len: usize = 0,

    /// 已拥有但尚未释放的存储字节数；所有权计数，不是容量上限。
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

    fn notify(self: *Bridge) void {
        if (self.notification) |n| n.notify_fn(n.context);
    }

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
    /// 只有 .text / .reasoning 会被切成多段逐个入队，其它事件仍是一条一次。
    fn emit(ctx: ?*anyopaque, event: r.Event, cancel: *const p.Cancellation) anyerror!void {
        const self = from(ctx);
        self.lock();
        // 中文：finished 不进入队列，只保存终态，也不占用预算。
        if (event == .finished) {
            self.terminal = event.finished;
            self.clearPermission();
            self.unlock();
            self.notify();
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

        // 中文：流式正文可能一次远大于单条 item_budget（例如非流式应答整段下发）。
        // 原先 Copy.text 会把超出部分静默截断，TUI 永久丢失已生成内容，因此只对
        // text / reasoning 按 UTF-8 边界切段，逐段走同一条既定入队路径。
        // 单生产者保证切片顺序入队、不与其它事件交错，因此无需额外屏障。
        switch (event) {
            .text => |body| try self.enqueueBody(.text, body, cancel),
            .reasoning => |body| try self.enqueueBody(.reasoning, body, cancel),
            else => try self.enqueue(event, cancel),
        }
    }

    /// 正文切片的种类，也决定每一段还原成哪种事件。
    const BodyKind = enum { text, reasoning };

    /// 把一段流式正文切成不超过 item_budget 的 UTF-8 安全片，逐片顺序入队。
    /// 空正文仍然入队一个空事件（与截断前的行为一致）；不整段预留预算。
    fn enqueueBody(self: *Bridge, kind: BodyKind, body: []const u8, cancel: *const p.Cancellation) anyerror!void {
        var offset: usize = 0;
        while (true) {
            const take = chunkLen(body[offset..], item_budget);
            const part = body[offset..][0..take];
            try self.enqueue(switch (kind) {
                .text => .{ .text = part },
                .reasoning => .{ .reasoning = part },
            }, cancel);
            offset += take;
            if (offset >= body.len) return;
        }
    }

    /// 单条事件的两阶段入队：锁内测量并预留预算 -> 锁外分配并拷贝 -> 锁内入队。
    /// 队列满或预算不足时短暂让出重试；每段入队后唤醒消费者，让切分的大正文
    /// 在消费端逐段回收预算，不会因为等待唤醒而死锁。
    fn enqueue(self: *Bridge, event: r.Event, cancel: *const p.Cancellation) anyerror!void {
        // 中文：第一遍只测量需要的字节数，不做分配。
        var measure = Copy{};
        _ = measure.event(event);
        // Allocate and copy outside the lock; admission below is transactional.
        const storage = try self.allocator.alignedAlloc(u8, .of(p.Block), measure.used);
        errdefer self.allocator.free(storage);
        var copy = Copy{ .storage = storage };
        const owned = copy.event(event);

        {
            self.lock();
            defer self.unlock();
            // 中文：分配期间 UI 可能已断开或被取消，入队前必须再检查一次。
            if (self.stopped(cancel)) return error.Canceled;
            try self.queue.append(self.allocator, .{ .event = owned, .display_truncated = copy.clipped, .canonical_complete = copy.canonical_complete, .storage = storage, .owner = self });
            self.len += 1;
            self.bytes += measure.used;
            self.outstanding += 1;
        }
        self.notify();
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
        const item = self.queue.items[self.head];
        self.head += 1;
        self.len -= 1;
        if (self.len == 0) {
            self.queue.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head >= self.len) {
            std.mem.copyForwards(Item, self.queue.items[0..self.len], self.queue.items[self.head..]);
            self.queue.items.len = self.len;
            self.head = 0;
        }
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
    }

    /// 关闭并释放桥。调用前工作线程必须已 join；会逐个弹出并 deinit 残留的 Item。
    pub fn deinit(self: *Bridge) void {
        self.close();
        std.debug.assert(self.active == 0);

        // 中文：残留 Item 必须逐个释放，否则统计与分配内存都会泄漏。
        while (self.pop()) |item_| {
            var item = item_;
            item.deinit();
        }

        std.debug.assert(self.outstanding == 0 and self.bytes == 0);
        self.queue.deinit(self.allocator);
        std.debug.assert(std.c.pthread_mutex_destroy(&self.mutex) == .SUCCESS);
        self.* = undefined;
    }
};

// Regression: tool_view.task/id snapshots stayed borrowed from the producer's
// JSON extractor, so encoding them after the producer moved on read freed
// memory (worker segfault on the second background-management round). All six
// snapshot fields must be owned by the Item, not merely byte-equal.

// The shared measure/copy budget must account for task and stop on a codepoint
// boundary; UTF-8 safety here mirrors the existing field-cap coverage.

// 中文：以下为正文切片入队的定点测试。它们只在本文件的私有测试根中运行，
// 不联网、不执行工具，也不依赖其它模块的测试夹具。

// 一次入队进度的只读快照（持锁读取，供测试观察生产者线程）。

// 201 KiB 的三字节字符正文：长度可被 3 整除，因此每个切片都必须回退到码点边界。

// 测试用生产者：把一段正文交给 Bridge，并记录返回值供主线程断言。

// 逐个 pop 并核对：所有条目都是同一种正文事件、按顺序精确拼回 expected、
// 每段不超过 item_budget 且没有截断/不完整标记，存储归 Item 所有。
