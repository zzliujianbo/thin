//! 实例内后台命令管理器：Job 所有权、有界日志环、状态/停止与退出收敛。
//!
//! 每个 Job 独立持有 root 目录描述符、精简环境副本、命令、自有取消令牌、
//! 日志环与 worker Future；worker 不访问父配置、Runtime 或注册表。数量不设
//! 配额；cleanup_failed 保留完整 Job 并让实例拒绝新的后台启动（poison）。

const std = @import("std");
const builtin = @import("builtin");
const bg = @import("../core/background.zig");
const p = @import("../core/protocol.zig");
const fs = @import("../platform/filesystem.zig");
const process = @import("../platform/process.zig");

const c = std.c;

/// 由 App 初始化一次；不重置已有注册表，也不重建已启动的 Job。
pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: *const fs.Root,
    environment: *const std.process.Environ.Map,
};

/// worker 返回值：只含标量，安全跨线程复制。
pub const Outcome = struct {
    term: ?std.process.Child.Term = null,
    cleanup_failed: bool = false,
    canceled: bool = false,
    timed_out: bool = false,
    truncated: bool = false,
    unreaped_pid: ?c.pid_t = null,
    exit_error: ?anyerror = null,
    stdout_bytes: u64 = 0,
    stderr_bytes: u64 = 0,
};

/// 短临界区自旋锁：只包日志环的定长拷贝，不跨阻塞调用持有。
const Spin = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *Spin) void {
        var spins: usize = 0;
        while (self.locked.swap(true, .acquire)) {
            spins +%= 1;
            std.atomic.spinLoopHint();
            if (spins % 1024 == 0) std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *Spin) void {
        self.locked.store(false, .release);
    }
};

/// 覆盖旧数据时准确推进 `available_from` 的原始字节环。
const Ring = struct {
    buf: []u8,
    /// 下一次写入位置。
    next: usize = 0,
    /// 当前保留字节数，上限为容量。
    len: usize = 0,
    /// 收到过的原始字节总数（饱和累加）。
    total: u64 = 0,

    fn append(self: *Ring, bytes: []const u8) void {
        self.total +|= bytes.len;
        if (self.buf.len == 0) return;
        var rest = bytes;
        while (rest.len != 0) {
            const take = @min(self.buf.len - self.next, rest.len);
            @memcpy(self.buf[self.next..][0..take], rest[0..take]);
            self.next = (self.next + take) % self.buf.len;
            rest = rest[take..];
        }
        self.len = @min(self.len + bytes.len, self.buf.len);
    }

    const Read = struct {
        start: u64 = 0,
        end: u64 = 0,
        lost: u64 = 0,
        len: usize = 0,
        /// 快照时刻的总量与最旧可用游标，和本次拷贝取自同一临界区。
        total_bytes: u64 = 0,
        available_from: u64 = 0,
    };

    /// 从绝对游标 `offset` 读取至多 `dst.len` 原始字节；早于 `available_from`
    /// 的部分记为 lost，并以 available_from 为真实起点。
    fn readInto(self: *const Ring, offset: u64, dst: []u8) Read {
        const total = self.total;
        const from = total - self.len;
        const lost: u64 = if (offset < from) from - offset else 0;
        const start = @max(offset, from);
        if (start >= total or dst.len == 0 or self.buf.len == 0)
            return .{ .start = start, .end = start, .lost = lost, .total_bytes = total, .available_from = from };
        const len: usize = @intCast(@min(total - start, dst.len));
        // 绝对位置 p 对应环内下标 (next + p - total) mod cap。
        const delta: usize = @intCast(total - start);
        var index = (self.next + self.buf.len - (delta % self.buf.len)) % self.buf.len;
        var copied: usize = 0;
        while (copied < len) {
            const take = @min(self.buf.len - index, len - copied);
            @memcpy(dst[copied..][0..take], self.buf[index..][0..take]);
            copied += take;
            index = (index + take) % self.buf.len;
        }
        return .{ .start = start, .end = start + len, .lost = lost, .len = len, .total_bytes = total, .available_from = from };
    }

    fn deinitWiped(self: *Ring, a: std.mem.Allocator) void {
        wipe(self.buf);
        a.free(self.buf);
        self.* = undefined;
    }
};

const Logs = struct {
    mutex: Spin = .{},
    streams: [2]Ring,

    /// stdout 取上取整、stderr 取下取整，两路合计不超过给定预算。
    fn init(a: std.mem.Allocator, budget: u32) !Logs {
        const out_buf = try a.alloc(u8, (budget + 1) / 2);
        errdefer a.free(out_buf);
        const err_buf = try a.alloc(u8, budget / 2);
        return .{ .streams = .{ .{ .buf = out_buf }, .{ .buf = err_buf } } };
    }

    fn append(self: *Logs, which: usize, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.streams[which].append(bytes);
    }

    fn read(self: *Logs, which: usize, offset: u64, dst: []u8) Ring.Read {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.streams[which].readInto(offset, dst);
    }

    fn totals(self: *Logs) [2]u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ self.streams[0].total, self.streams[1].total };
    }

    fn deinitWiped(self: *Logs, a: std.mem.Allocator) void {
        for (&self.streams) |*stream| stream.deinitWiped(a);
        self.* = undefined;
    }
};

/// 一个稳定、独立分配的后台任务；终态与日志保留到实例退出。
const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    id: []u8,
    command: []u8,
    root: fs.Root,
    env: std.process.Environ.Map,
    /// Job 自己的取消令牌：不持有 root/父令牌指针，也不受其影响。
    cancel: p.Cancellation = .{},
    logs: Logs,
    term_grace_ms: u32,
    cleanup_timeout_ms: u32,
    /// 真实启动时刻（awake 单调时钟）。
    started: std.Io.Timestamp,

    /// 启动握手：0 未决、1 成功、2 失败。由 worker 线程写入。
    launch: std.atomic.Value(u8) = .init(0),
    launched_pid: std.atomic.Value(i32) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    stop_requested: std.atomic.Value(bool) = .init(false),
    /// worker 完成时先写 outcome，再以 release 置 done；只有 acquire 读到
    /// done==true 后读取它才是安全的。
    outcome: Outcome = .{},
    future: ?std.Io.Future(Outcome) = null,

    fn publish(self: *Job, out: Outcome) void {
        self.outcome = out;
        self.done.store(true, .release);
    }

    fn destroy(self: *Job) void {
        const a = self.allocator;
        wipe(self.command);
        a.free(self.command);
        a.free(self.id);
        deinitEnvironmentWiped(&self.env);
        self.logs.deinitWiped(a);
        self.root.deinit();
        a.destroy(self);
    }
};

/// 释放前擦除可能含敏感值的内存（命令、环境键值、日志环）。
fn wipe(bytes: []u8) void {
    for (bytes) |*byte| @as(*volatile u8, @ptrCast(byte)).* = 0;
}

fn deinitEnvironmentWiped(env: *std.process.Environ.Map) void {
    var it = env.iterator();
    while (it.next()) |entry| {
        wipe(@constCast(entry.key_ptr.*));
        wipe(@constCast(entry.value_ptr.*));
    }
    env.deinit();
}

fn cloneEnvironment(a: std.mem.Allocator, source: *const std.process.Environ.Map) !std.process.Environ.Map {
    var result = std.process.Environ.Map.init(a);
    errdefer deinitEnvironmentWiped(&result);
    var it = source.iterator();
    while (it.next()) |entry| try result.put(entry.key_ptr.*, entry.value_ptr.*);
    return result;
}

fn elapsedMs(io: std.Io, since: std.Io.Timestamp) u64 {
    const ms = since.untilNow(io, .awake).toMilliseconds();
    return if (ms <= 0) 0 else @intCast(ms);
}

fn stateName(job: *Job, out: Outcome, running: bool) []const u8 {
    if (out.cleanup_failed) return "cleanup_failed";
    if (running) return if (job.launch.load(.acquire) == 0) "starting" else "running";
    if (out.exit_error != null) return "failed";
    if (job.stop_requested.load(.acquire)) return "stopped";
    return "exited";
}

/// 沙箱外的实例级后台服务管理器；只由 App 持有。
pub const BackgroundService = struct {
    /// 默认 `.{}` 空可析构（此时断言没有任何 Job）。
    deps: ?Dependencies = null,
    /// 按登记顺序保存；worker 绝不修改此容器。
    jobs: std.ArrayList(*Job) = .empty,
    /// 128 位随机实例前缀（32 位小写十六进制），拒绝跨实例 ID。
    prefix: [32]u8 = undefined,
    prefix_ready: bool = false,
    next_seq: u64 = 0,
    /// 任何已观察到的 cleanup_failed 都使实例不再接受新的后台启动。
    poison: std.atomic.Value(bool) = .init(false),
    /// 仅测试使用（`builtin.is_test` 下才生效）：模拟慢启动，生产恒为 0。
    test_hold_handshake_ms: u64 = 0,

    /// 单个 Job 日志环总量上限（内存合理边界，不是任务数量配额）。
    pub const max_log_bytes: u32 = 64 * 1024 * 1024;
    pub const max_command_bytes: usize = 32768;

    pub fn service(self: *BackgroundService) bg.Service {
        return .{ .context = self, .start_fn = startFn, .control_fn = controlFn, .check_fn = checkFn };
    }

    fn startFn(context: *anyopaque, a: std.mem.Allocator, args: bg.Start, cancel: *const p.Cancellation) anyerror!bg.Result {
        return @as(*BackgroundService, @ptrCast(@alignCast(context))).start(a, args, cancel);
    }

    fn controlFn(context: *anyopaque, a: std.mem.Allocator, query: bg.Query, cancel: *const p.Cancellation) anyerror!bg.Result {
        return @as(*BackgroundService, @ptrCast(@alignCast(context))).control(a, query, cancel);
    }

    fn checkFn(context: *anyopaque) anyerror!void {
        const self: *BackgroundService = @ptrCast(@alignCast(context));
        if (self.unhealthy()) return error.CleanupFailed;
    }

    /// 启动预算校验：拒绝 0 启动窗口、0 清理预算、非法命令与超限日志。
    pub fn validateStart(args: bg.Start) !void {
        if (args.command.len == 0 or args.command.len > max_command_bytes) return error.InvalidCommand;
        if (std.mem.indexOfScalar(u8, args.command, 0) != null) return error.InvalidCommand;
        if (!std.unicode.utf8ValidateSlice(args.command)) return error.InvalidCommand;
        if (args.startup_timeout_ms == 0) return error.InvalidStartupTimeout;
        if (args.cleanup_timeout_ms == 0) return error.InvalidCleanupTimeout;
        if (args.log_bytes > max_log_bytes) return error.InvalidLogBudget;
    }

    fn depsOrFail(self: *BackgroundService) !Dependencies {
        return self.deps orelse error.BackgroundUnavailable;
    }

    fn ensurePrefix(self: *BackgroundService, deps: Dependencies) !void {
        if (self.prefix_ready) return;
        var raw: [16]u8 = undefined;
        try deps.io.randomSecure(&raw);
        const hex = "0123456789abcdef";
        for (raw, 0..) |byte, i| {
            self.prefix[i * 2] = hex[byte >> 4];
            self.prefix[i * 2 + 1] = hex[byte & 15];
        }
        self.prefix_ready = true;
    }

    /// job 结束并已 join 后才可释放；调用前必须确认所有权已收敛。
    fn resolve(self: *BackgroundService, id: []const u8) ?*Job {
        if (!self.prefix_ready) return null;
        const separator = std.mem.indexOfScalar(u8, id, '-') orelse return null;
        if (separator != self.prefix.len) return null;
        if (!std.mem.eql(u8, id[0..separator], self.prefix[0..])) return null;
        _ = std.fmt.parseInt(u64, id[separator + 1 ..], 10) catch return null;
        for (self.jobs.items) |job| {
            if (std.mem.eql(u8, job.id, id)) return job;
        }
        return null;
    }

    fn remove(self: *BackgroundService, job: *Job) void {
        for (self.jobs.items, 0..) |candidate, i| {
            if (candidate == job) {
                _ = self.jobs.orderedRemove(i);
                return;
            }
        }
    }

    /// 只有 done（acquire）后才有权读取 outcome；仍在运行的 Job 返回零值快照。
    fn observed(self: *BackgroundService, job: *Job) Outcome {
        if (!job.done.load(.acquire)) return .{};
        return self.join(job);
    }

    fn join(self: *BackgroundService, job: *Job) Outcome {
        var future = job.future orelse return job.outcome;
        job.future = null;
        const out = future.await(job.io);
        job.outcome = out;
        if (out.cleanup_failed or out.unreaped_pid != null) self.poison.store(true, .release);
        return out;
    }

    /// 异步观察到的清理失败也必须让本轮失败：扫描已完成 Job 的真实终态。
    fn unhealthy(self: *BackgroundService) bool {
        if (self.poison.load(.acquire)) return true;
        for (self.jobs.items) |job| {
            if (!job.done.load(.acquire)) continue;
            const out = job.outcome;
            if (out.cleanup_failed or out.unreaped_pid != null) {
                self.poison.store(true, .release);
                return true;
            }
        }
        return false;
    }

    /// 构造 Job：内部 errdefer 只在失败时撤销已取得的资源，成功即返回单一 owner。
    fn createJob(deps: Dependencies, id: []u8, args: bg.Start) !*Job {
        const a = deps.allocator;
        const job = try a.create(Job);
        errdefer a.destroy(job);
        const command = try a.dupe(u8, args.command);
        errdefer {
            wipe(command);
            a.free(command);
        }
        var root = try deps.root.duplicate();
        errdefer root.deinit();
        var logs = try Logs.init(a, args.log_bytes);
        errdefer logs.deinitWiped(a);
        job.* = .{
            .allocator = a,
            .io = deps.io,
            .id = id,
            .command = command,
            .root = root,
            .env = try cloneEnvironment(a, deps.environment),
            .logs = logs,
            .term_grace_ms = args.term_grace_ms,
            .cleanup_timeout_ms = args.cleanup_timeout_ms,
            .started = std.Io.Clock.awake.now(deps.io),
        };
        return job;
    }

    fn formatId(self: *BackgroundService, a: std.mem.Allocator) ![]u8 {
        if (self.next_seq == std.math.maxInt(u64)) return error.SequenceExhausted;
        const seq = self.next_seq;
        self.next_seq += 1;
        return std.fmt.allocPrint(a, "{s}-{d}", .{ self.prefix[0..], seq });
    }

    const Requested = enum { none, canceled, timed_out };

    /// 有界等待启动握手；取消/超时优先于握手结果判定。
    fn waitHandshake(self: *BackgroundService, job: *Job, budget_ms: u32, cancel: *const p.Cancellation) Requested {
        const io = job.io;
        const since = std.Io.Clock.awake.now(io);
        const hold: u64 = if (builtin.is_test) self.test_hold_handshake_ms else 0;
        while (true) {
            if (cancel.isRequested()) return .canceled;
            io.checkCancel() catch return .canceled;
            if (elapsedMs(io, since) >= budget_ms) return .timed_out;
            const held = elapsedMs(io, since) < hold;
            if (!held and (job.launch.load(.acquire) != 0 or job.done.load(.acquire))) return .none;
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch return .canceled;
        }
    }

    fn canceledResult(a: std.mem.Allocator, id: []const u8, reason: []const u8) !bg.Result {
        return .{
            .text = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"state\":\"failed\",\"reason\":\"{s}\"}}", .{ id, reason }),
            .is_error = true,
            .canceled = true,
        };
    }

    pub fn start(self: *BackgroundService, a: std.mem.Allocator, args: bg.Start, cancel: *const p.Cancellation) !bg.Result {
        const deps = try self.depsOrFail();
        if (self.unhealthy()) return error.BackgroundUnavailable;
        try validateStart(args);
        // 预取消不 spawn，也不申请资源。
        if (cancel.isRequested()) return canceledResult(a, "none", "canceled before spawn");
        deps.io.checkCancel() catch return canceledResult(a, "none", "canceled before spawn");

        try self.ensurePrefix(deps);
        // 登记容量在分配 ID 与 spawn 前预留：容量不足时不泄漏已分配的 ID。
        try self.jobs.ensureUnusedCapacity(deps.allocator, 1);
        const id = try self.formatId(deps.allocator);
        const job = createJob(deps, id, args) catch |e| {
            deps.allocator.free(id);
            return e;
        };
        // 创建成功前 Job 的唯一 owner 是这个 defer；worker 起来后由 Job 自己拥有。
        var worker_started = false;
        defer if (!worker_started) job.destroy();

        var receipt: ?[]u8 = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"state\":\"started\"}}", .{id});
        defer if (receipt) |text| a.free(text);
        job.future = try std.Io.concurrent(deps.io, worker, .{job});
        worker_started = true;
        self.jobs.appendAssumeCapacity(job);

        const reason = self.waitHandshake(job, args.startup_timeout_ms, cancel);
        // 交接前的最后检查：握手成功也可能刚收到取消。
        const launched = job.launch.load(.acquire) == 1;
        var caller_canceled = reason == .canceled;
        if (reason == .none and launched) {
            if (cancel.isRequested()) caller_canceled = true;
            deps.io.checkCancel() catch {
                caller_canceled = true;
            };
        }

        if (reason != .none or !launched or caller_canceled) {
            job.cancel.cancel();
            const out = self.join(job);
            if (out.cleanup_failed or out.unreaped_pid != null) {
                // 原地保留完整 Job（含 owned/unreaped PID），实例不再接受新启动。
                self.poison.store(true, .release);
                // 已知 cleanup_failed：状态编码失败也必须升级为该错误，不让 OOM 覆盖。
                const text = statusText(a, job.io, job, out) catch return error.CleanupFailed;
                return .{
                    .text = text,
                    .is_error = true,
                    .cleanup_failed = true,
                    .canceled = caller_canceled,
                };
            }
            self.remove(job);
            // 出表后立即接管释放，后续编码失败也不会丢掉 Job。
            defer job.destroy();
            const failure_text = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"state\":\"failed\",\"reason\":\"{s}\"}}", .{
                job.id,
                if (caller_canceled) "canceled before handoff" else if (reason == .timed_out) "startup timed out" else "startup failed",
            });
            return .{ .text = failure_text, .is_error = true, .canceled = caller_canceled };
        }

        const text = receipt.?;
        receipt = null;
        return .{ .text = text };
    }

    pub fn control(self: *BackgroundService, a: std.mem.Allocator, query: bg.Query, cancel: *const p.Cancellation) !bg.Result {
        _ = try self.depsOrFail();
        bg.validateQuery(query) catch return bg.Result.failed(try invalidArguments(a));
        switch (query.action) {
            .list => return .{ .text = try self.listText(a, query, cancel), .canceled = cancel.isRequested() },
            .status => {
                const job = self.resolve(query.id.?) orelse return try unknownId(a, query.id.?);
                const out = self.observed(job);
                // 已知 cleanup_failed：状态编码失败升级为该错误，不让 OOM 覆盖。
                const text = statusText(a, job.io, job, out) catch |e|
                    return if (out.cleanup_failed or out.unreaped_pid != null) error.CleanupFailed else e;
                return .{ .text = text, .cleanup_failed = out.cleanup_failed };
            },
            .logs => {
                const job = self.resolve(query.id.?) orelse return try unknownId(a, query.id.?);
                return logsResult(a, job, query);
            },
            .stop => {
                const job = self.resolve(query.id.?) orelse return try unknownId(a, query.id.?);
                // 先收取已自然结束的 Job 终态，避免 stop 把保留终态改写成 stopped。
                var out = self.observed(job);
                // 重复 stop 只查询保留记录：future 已消费后不再发信号。
                if (job.future != null) {
                    job.stop_requested.store(true, .release);
                    job.cancel.cancel();
                    out = self.join(job);
                }
                const text = statusText(a, job.io, job, out) catch |e|
                    return if (out.cleanup_failed or out.unreaped_pid != null) error.CleanupFailed else e;
                return .{ .text = text, .cleanup_failed = out.cleanup_failed };
            },
        }
    }

    fn invalidArguments(a: std.mem.Allocator) ![]const u8 {
        return a.dupe(u8, "{\"error\":\"invalid background arguments\"}");
    }

    /// 未知 ID 的结果文本同样由调用方分配器拥有，OOM 必须向上传播。
    fn unknownId(a: std.mem.Allocator, id: []const u8) !bg.Result {
        return .{
            .text = try std.fmt.allocPrint(a, "{{\"error\":\"unknown background id\",\"id\":\"{s}\"}}", .{id}),
            .is_error = true,
        };
    }

    fn listText(self: *BackgroundService, a: std.mem.Allocator, query: bg.Query, cancel: *const p.Cancellation) ![]const u8 {
        const io = self.deps.?.io;
        const after = query.after orelse 0;
        const limit: u64 = bg.pageLimit(query);
        const total: u64 = self.jobs.items.len;
        const first: usize = @intCast(@min(after, total));

        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        const w = &out.writer;
        try w.print("{{\"action\":\"list\",\"total\":{d},\"after\":{d},\"services\":[", .{ total, after });
        var listed: u64 = 0;
        var i = first;
        while (i < self.jobs.items.len and listed < limit) : (i += 1) {
            if (cancel.isRequested()) break;
            io.checkCancel() catch break;
            const job = self.jobs.items[i];
            const out_state = self.observed(job);
            if (listed != 0) try w.writeByte(',');
            try writeJobObject(w, io, job, out_state);
            listed += 1;
        }
        const next = @min(after +| listed, total);
        try w.print("],\"next\":{d},\"has_more\":{s}}}", .{ next, if (next < total) "true" else "false" });
        return out.toOwnedSlice() catch return error.WriteFailed;
    }

    /// 每路的 total_bytes/available_from/游标都来自同一临界区快照。
    fn logsResult(a: std.mem.Allocator, job: *Job, query: bg.Query) !bg.Result {
        const budget: u32 = bg.logBudget(query);
        const out_budget: usize = @min((budget + 1) / 2, bg.max_log_budget);
        const err_budget: usize = @min(budget / 2, bg.max_log_budget);
        var raw_out: [bg.max_log_budget]u8 = undefined;
        var raw_err: [bg.max_log_budget]u8 = undefined;
        const out_offset = query.stdout_offset orelse 0;
        const err_offset = query.stderr_offset orelse 0;
        const out_read = job.logs.read(0, out_offset, raw_out[0..out_budget]);
        const err_read = job.logs.read(1, err_offset, raw_err[0..err_budget]);
        if (out_offset > out_read.total_bytes or err_offset > err_read.total_bytes)
            return .{ .text = try std.fmt.allocPrint(a, "{{\"error\":\"invalid log offset\",\"id\":\"{s}\"}}", .{job.id}), .is_error = true };

        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        const w = &out.writer;
        try w.print("{{\"action\":\"logs\",\"id\":", .{});
        try writeString(w, job.id);
        try w.print(",\"budget\":{d},\"stdout\":", .{budget});
        try writeStreamLog(w, a, out_read, raw_out[0..out_read.len]);
        try w.print(",\"stderr\":", .{});
        try writeStreamLog(w, a, err_read, raw_err[0..err_read.len]);
        const truncated = out_read.lost != 0 or err_read.lost != 0 or
            out_read.end < out_read.total_bytes or err_read.end < err_read.total_bytes;
        try w.print(",\"truncated\":{s}}}", .{if (truncated) "true" else "false"});
        return .{ .text = out.toOwnedSlice() catch return error.WriteFailed, .truncated = truncated };
    }

    /// 退出：先对所有 Job 请求取消，再统一 join；无法确认收敛时 fail-stop，
    /// 既不释放容器，也不把清理失败当成普通成功。
    pub fn deinit(self: *BackgroundService) void {
        const deps = self.deps orelse {
            std.debug.assert(self.jobs.items.len == 0);
            self.* = .{};
            return;
        };
        for (self.jobs.items) |job| job.cancel.cancel();
        var unclean = false;
        for (self.jobs.items) |job| {
            const out = self.join(job);
            if (out.cleanup_failed or out.unreaped_pid != null) {
                unclean = true;
                continue;
            }
            job.destroy();
        }
        if (unclean) {
            std.debug.print("thin: background cleanup unconfirmed; failing stop\n", .{});
            @panic("background job cleanup unconfirmed");
        }
        self.jobs.deinit(deps.allocator);
        self.* = .{};
    }
};

/// worker 线程：只通过 Job 自己的 token/root/env/log 运行；无命令 deadline。
fn worker(job: *Job) Outcome {
    const options: process.Options = .{
        .timeout_ms = null,
        .output_bytes = 0,
        .term_grace_ms = job.term_grace_ms,
        .cleanup_timeout_ms = job.cleanup_timeout_ms,
        .cwd_dir = job.root.dir,
        .stdout_sink = .{ .context = job, .write_fn = stdoutSink },
        .stderr_sink = .{ .context = job, .write_fn = stderrSink },
        // Log sinks are passive bounded appends: keep draining TERM cleanup.
        .continue_sinks_on_cancel = true,
        .on_launch = .{ .context = job, .notify_fn = launchNotify },
    };
    const result = process.run(job.allocator, job.io, job.root.path, job.command, &job.env, options, &job.cancel) catch |e| {
        // process.run 只在 fork 前失败或清理已成功后才返回错误：如实记录，不伪造 cleanup_failed。
        const out: Outcome = .{ .exit_error = e };
        job.publish(out);
        return out;
    };
    defer {
        job.allocator.free(result.stdout);
        job.allocator.free(result.stderr);
    }
    const out: Outcome = .{
        .term = result.term,
        .cleanup_failed = result.cleanup_failed,
        .canceled = result.canceled,
        .timed_out = result.timed_out,
        .truncated = result.truncated,
        .unreaped_pid = result.unreaped_pid,
        .stdout_bytes = result.stdout_bytes,
        .stderr_bytes = result.stderr_bytes,
    };
    job.publish(out);
    return out;
}

fn stdoutSink(context: *anyopaque, bytes: []const u8) anyerror!void {
    const job: *Job = @ptrCast(@alignCast(context));
    job.logs.append(0, bytes);
}

fn stderrSink(context: *anyopaque, bytes: []const u8) anyerror!void {
    const job: *Job = @ptrCast(@alignCast(context));
    job.logs.append(1, bytes);
}

/// 只有 exec 成功且确认进程组归属，才算可交接的启动。
fn launchNotify(context: *anyopaque, notice: process.LaunchNotice) void {
    const job: *Job = @ptrCast(@alignCast(context));
    job.launched_pid.store(@intCast(notice.pid), .release);
    job.launch.store(if (notice.launched and notice.group_owned) 1 else 2, .release);
}

fn writeString(w: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, w);
}

fn writeStreamLog(w: *std.Io.Writer, a: std.mem.Allocator, read: Ring.Read, raw: []const u8) !void {
    const text = try process.renderSafeText(a, raw);
    defer a.free(text);
    try w.print("{{\"offset\":{d},\"next_offset\":{d},\"available_from\":{d},\"total_bytes\":{d},\"lost_bytes\":{d},\"text\":", .{
        read.start, read.end, read.available_from, read.total_bytes, read.lost,
    });
    try writeString(w, text);
    try w.writeAll("}");
}

fn writeJobObject(w: *std.Io.Writer, io: std.Io, job: *Job, out: Outcome) !void {
    // observed() 完成时已 join 并把 future 置空，这里不再二次读 done，避免快照错位。
    const running = job.future != null;
    const totals = job.logs.totals();
    try w.writeAll("{\"id\":");
    try writeString(w, job.id);
    try w.print(",\"state\":\"{s}\"", .{stateName(job, out, running)});
    try w.print(",\"pid\":{d}", .{job.launched_pid.load(.acquire)});
    try w.print(",\"started_ms\":{d},\"elapsed_ms\":{d}", .{
        job.started.toMilliseconds(), elapsedMs(io, job.started),
    });
    if (out.term) |term| switch (term) {
        .exited => |code| try w.print(",\"exit_code\":{d}", .{code}),
        .signal => |sig| try w.print(",\"signal\":{d}", .{sig}),
        .stopped => |sig| try w.print(",\"stopped_signal\":{d}", .{sig}),
        .unknown => |code| try w.print(",\"unknown_status\":{d}", .{code}),
    };
    if (out.unreaped_pid) |pid| try w.print(",\"unreaped_pid\":{d}", .{pid});
    try w.print(",\"canceled\":{s},\"timed_out\":{s},\"cleanup_failed\":{s}", .{
        if (out.canceled) "true" else "false",
        if (out.timed_out) "true" else "false",
        if (out.cleanup_failed) "true" else "false",
    });
    if (out.exit_error) |err| try w.print(",\"error\":\"{s}\"", .{@errorName(err)});
    try w.print(",\"stdout_bytes\":{d},\"stderr_bytes\":{d}}}", .{ totals[0], totals[1] });
}

fn statusText(a: std.mem.Allocator, io: std.Io, job: *Job, out: Outcome) ![]const u8 {
    var out_writer: std.Io.Writer.Allocating = .init(a);
    defer out_writer.deinit();
    const w = &out_writer.writer;
    try w.print("{{\"action\":\"status\",\"service\":", .{});
    try writeJobObject(w, io, job, out);
    try w.writeAll("}");
    return out_writer.toOwnedSlice() catch return error.WriteFailed;
}
