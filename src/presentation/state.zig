//! 共享的接收端展示状态。调用方提供时钟并同步消费borrowed事件；不保留文本指针，
//! 不读取Runtime/配置/凭据/归档。App传入不可变配置档位，不能从流时长猜测档位。

const r = @import("../core/runtime.zig");

const activity = @import("activity.zig");

pub const ContextSnapshot = r.ContextSnapshot;

/// 最近一次请求的实际占用比例(千分比=百分比的小数一位、四舍五入)，不累计/不减cached。
/// u128中间值防止输入极值溢出；缺usage/容量为unknown，而非虚构0%。
pub fn contextRatio(snapshot: ContextSnapshot) ?u128 {
    if (!snapshot.known or snapshot.limit == 0) return null;
    return (@as(u128, snapshot.tokens) * 1000 + snapshot.limit / 2) / snapshot.limit;
}

/// Only what a frontend actually renders: occupancy, live receive rate, its band
/// and the configured effort. No cumulative billing, TTFT or elapsed totals.
pub const View = struct {
    context: ?ContextSnapshot,
    live_tps_tenths: ?u64,
    rate_band: activity.RateBand,
    reasoning_effort: activity.ReasoningEffort,
    /// Display deltas are arriving right now. Only this state animates the
    /// model label; a busy turn that produces no tokens stays static.
    streaming: bool = false,
};

pub const State = struct {
    meter: activity.Meter = .{},
    context: ?ContextSnapshot = null,
    reasoning_effort: activity.ReasoningEffort = .unspecified,

    /// 开始新turn，不抹去仍然保留的ctx或不可变配置档位；实时窗口按turn重置。
    pub fn reset(self: *State) void {
        self.meter.reset();
    }
    pub fn seed(self: *State, initial: ?ContextSnapshot) void {
        if (self.context == null) self.context = initial;
    }
    pub fn setEffort(self: *State, effort: activity.ReasoningEffort) void {
        self.reasoning_effort = effort;
    }
    pub fn observe(self: *State, event: r.Event, now_ms: u64) void {
        switch (event) {
            .state => |phase| {
                if (phase == .calling_model) self.meter.beginCall() else self.meter.endCall();
            },
            .text, .reasoning => |bytes| self.meter.observe(now_ms, bytes),
            .tool_preview => |delta| self.meter.observe(now_ms, delta.arguments),
            .usage => |usage| {
                if (self.context) |snapshot| {
                    const total = usage.value.total();
                    self.context = .{ .tokens = total orelse 0, .limit = snapshot.limit, .known = total != null };
                }
                // A completed normal request is no longer generating; the
                // summary request that may follow opens its own window.
                if (usage.purpose == .normal) self.meter.endCall();
            },
            .context_snapshot => |snapshot| self.context = snapshot,
            .finished => |result| self.finish(result),
            else => {},
        }
    }
    pub fn finish(self: *State, result: r.Terminal) void {
        if (result.context_snapshot) |snapshot| self.context = snapshot;
        self.meter.endCall();
    }
    pub fn view(self: *const State, now_ms: u64) View {
        const live_rate = self.meter.liveRate(now_ms);
        return .{
            .context = self.context,
            .live_tps_tenths = live_rate,
            .rate_band = activity.rateBand(live_rate),
            .reasoning_effort = self.reasoning_effort,
            .streaming = self.meter.streaming(),
        };
    }
};
