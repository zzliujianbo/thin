//! 共享的接收端展示状态。调用方提供时钟并同步消费borrowed事件；不保留文本指针，
//! 不读取Runtime/配置/凭据/归档。TUI和未来Web宿主可使用相同observe/view逻辑。
const std = @import("std");
const r = @import("../core/runtime.zig");
const p = @import("../core/protocol.zig");
const activity = @import("activity.zig");

pub const ContextSnapshot = r.ContextSnapshot;

/// 当前保留上下文的估算比例(千分比=百分比的小数一位)，不是billing/cache比例。
/// u128中间值防止输入极值溢出；无容量为unknown，而非0%。
pub fn contextRatio(snapshot: ContextSnapshot) ?u128 {
    if (snapshot.limit == 0) return null;
    return @as(u128, snapshot.tokens) * 1000 / snapshot.limit;
}

pub const View = struct {
    running: bool,
    phase: ?r.State,
    status: ?r.Status,
    context: ?ContextSnapshot,
    context_estimated: bool = true,
    protocol: ?p.Protocol,
    live_tps_tenths: ?u64,
    average_tps_tenths: ?u64,
    estimated_average_tps_tenths: ?u64,
    ttft_ms: ?u64,
};

pub const State = struct {
    running: bool = false,
    phase: ?r.State = null,
    meter: activity.Meter = .{},
    context: ?ContextSnapshot = null,
    protocol: ?p.Protocol = null,
    normal_usage: p.Usage = .{},
    terminal: ?r.Terminal = null,

    /// 开始新turn，不抹去仍然保留的ctx；usage/计时按turn重置。
    pub fn reset(self: *State, now_ms: u64) void {
        self.meter.reset(now_ms);
        self.running = true;
        self.phase = null;
        self.normal_usage = .{};
        self.terminal = null;
    }
    pub fn seed(self: *State, initial: ?ContextSnapshot) void {
        if (self.context == null) self.context = initial;
    }
    pub fn observe(self: *State, event: r.Event, now_ms: u64) void {
        switch (event) {
            .state => |phase| {
                self.running = true;
                self.phase = phase;
                if (phase == .calling_model) self.meter.beginCall(now_ms) else self.meter.endCall(now_ms);
            },
            .text, .reasoning => |bytes| self.meter.observe(now_ms, bytes),
            .tool_preview => |delta| self.meter.observe(now_ms, delta.arguments),
            .usage => |usage| {
                self.protocol = usage.protocol;
                if (usage.purpose == .normal) {
                    self.normal_usage = usage.value;
                    self.meter.endCall(now_ms);
                }
            },
            .fallback => self.protocol = .chat,
            .context_snapshot => |snapshot| self.context = snapshot,
            .finished => |result| self.finish(result, now_ms),
            else => {},
        }
    }
    pub fn finish(self: *State, result: r.Terminal, now_ms: u64) void {
        self.terminal = result;
        self.running = false;
        self.phase = null;
        if (result.context_snapshot) |snapshot| self.context = snapshot;
        self.meter.finish(now_ms);
    }
    pub fn view(self: *const State, now_ms: u64) View {
        return .{
            .running = self.running,
            .phase = self.phase,
            .status = if (self.terminal) |result| result.status else null,
            .context = self.context,
            .protocol = self.protocol,
            .live_tps_tenths = self.meter.liveRate(now_ms),
            .average_tps_tenths = self.meter.average(if (self.terminal) |result| result.usage.normal.output_tokens else null),
            .estimated_average_tps_tenths = self.meter.estimatedAverage(),
            .ttft_ms = self.meter.ttft_ms,
        };
    }
};

test "shared receipt state drives context and throughput without terminal or billing inference" {
    var state: State = .{};
    state.seed(.{ .tokens = 100, .limit = 1000 });
    state.reset(0);
    state.observe(.{ .state = .calling_model }, 0);
    state.observe(.{ .text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }, 100);
    try std.testing.expectEqual(@as(?u64, 400), state.view(350).live_tps_tenths);
    state.observe(.{ .usage = .{ .protocol = .chat, .purpose = .normal, .value = .{ .input_tokens = 900, .cached_input_tokens = 800, .output_tokens = 20 } } }, 1000);
    state.observe(.{ .context_snapshot = .{ .tokens = 600, .limit = 1000 } }, 1000);
    try std.testing.expectEqual(@as(u64, 600), state.view(1000).context.?.tokens);
    state.observe(.{ .state = .executing_tool }, 1000);
    try std.testing.expect(state.view(5000).live_tps_tenths == null);
    state.observe(.{ .context_snapshot = .{ .tokens = 300, .limit = 1000 } }, 5000);
    state.observe(.{ .state = .calling_model }, 6000);
    state.observe(.{ .reasoning = "received" }, 6100);
    state.finish(.{ .status = .canceled, .context_snapshot = .{ .tokens = 250, .limit = 1000 }, .usage = .{ .normal = .{ .output_tokens = 40 } } }, 7000);
    const view = state.view(7000);
    try std.testing.expectEqual(@as(?u64, 200), view.average_tps_tenths);
    try std.testing.expectEqual(@as(u64, 250), view.context.?.tokens);
    try std.testing.expectEqual(@as(?u128, 250), contextRatio(view.context.?));
    try std.testing.expect(contextRatio(.{ .tokens = 1, .limit = 0 }) == null);
    try std.testing.expect(contextRatio(.{ .tokens = std.math.maxInt(u64), .limit = 1 }).? > 1000);
    state.reset(8000);
    try std.testing.expectEqual(@as(u64, 250), state.view(8000).context.?.tokens);
    try std.testing.expect(state.view(8000).average_tps_tenths == null);
}
