//! 共享的接收端展示状态。调用方提供时钟并同步消费borrowed事件；不保留文本指针，
//! 不读取Runtime/配置/凭据/归档。App传入不可变配置档位，不能从流时长猜测档位。
const std = @import("std");
const r = @import("../core/runtime.zig");
const p = @import("../core/protocol.zig");
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
        };
    }
};

test "configured effort is visible before output and independent of time deltas tools and reset" {
    var state: State = .{};
    state.setEffort(.high);
    try std.testing.expectEqual(activity.ReasoningEffort.high, state.view(0).reasoning_effort);
    state.reset();
    state.observe(.{ .state = .calling_model }, 0);
    try std.testing.expectEqual(activity.ReasoningEffort.high, state.view(60000).reasoning_effort);
    state.observe(.{ .reasoning = "received" }, 60000);
    state.observe(.{ .text = "body" }, 90000);
    state.observe(.{ .state = .executing_tool }, 100000);
    state.finish(.{ .status = .canceled });
    state.reset();
    try std.testing.expectEqual(activity.ReasoningEffort.high, state.view(300000).reasoning_effort);
    state.setEffort(.unspecified);
    try std.testing.expectEqual(activity.ReasoningEffort.unspecified, state.view(300000).reasoning_effort);
}

test "shared receipt state drives actual request context and live throughput without cumulative billing" {
    var state: State = .{};
    state.seed(.{ .tokens = 100, .limit = 1000 });
    state.reset();
    state.observe(.{ .state = .calling_model }, 0);
    state.observe(.{ .text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }, 100);
    try std.testing.expectEqual(@as(?u64, 400), state.view(350).live_tps_tenths);
    state.observe(.{ .usage = .{ .protocol = .chat, .purpose = .normal, .value = .{ .input_tokens = 900, .cached_input_tokens = 800, .output_tokens = 20 } } }, 1000);
    try std.testing.expectEqual(@as(u64, 920), state.view(1000).context.?.tokens);
    state.observe(.{ .context_snapshot = .{ .tokens = 920, .limit = 1000 } }, 1000);
    state.observe(.{ .state = .executing_tool }, 1000);
    try std.testing.expect(state.view(5000).live_tps_tenths == null);
    state.observe(.{ .usage = .{ .protocol = .chat, .purpose = .summary, .value = .{ .input_tokens = 290, .output_tokens = 10 } } }, 5000);
    state.observe(.{ .context_snapshot = .{ .tokens = 300, .limit = 1000 } }, 5000);
    state.observe(.{ .state = .calling_model }, 6000);
    state.observe(.{ .reasoning = "received" }, 6100);
    state.observe(.{ .usage = .{ .protocol = .chat, .purpose = .normal, .value = .{ .input_tokens = 230, .output_tokens = 20 } } }, 7000);
    state.finish(.{ .status = .canceled, .context_snapshot = .{ .tokens = 250, .limit = 1000 }, .usage = .{ .normal = .{ .output_tokens = 40 } } });
    const view = state.view(7000);
    // A finished request publishes no live rate; only the request itself does.
    try std.testing.expect(view.live_tps_tenths == null);
    try std.testing.expectEqual(@as(u64, 250), view.context.?.tokens);
    try std.testing.expectEqual(@as(?u128, 250), contextRatio(view.context.?));
    try std.testing.expectEqual(@as(?u128, 23), contextRatio(.{ .tokens = 22807, .limit = 1000000 }));
    try std.testing.expect(contextRatio(.{ .tokens = 1, .limit = 0 }) == null);
    try std.testing.expect(contextRatio(.{ .tokens = std.math.maxInt(u64), .limit = 1 }).? > 1000);
    state.reset();
    try std.testing.expectEqual(@as(u64, 250), state.view(8000).context.?.tokens);
    try std.testing.expect(state.view(8000).live_tps_tenths == null);
}

test "actual context waits for reported usage and never estimates text or adds caches twice" {
    for ([_]p.Protocol{ .chat, .responses }) |protocol| {
        var state: State = .{};
        state.seed(.{ .tokens = 0, .limit = 100000 });
        state.reset();
        state.observe(.{ .state = .calling_model }, 0);
        state.observe(.{ .text = "unreported text and tool output cannot invent token counts" }, 1);
        try std.testing.expectEqual(@as(?u128, 0), contextRatio(state.context.?));
        state.observe(.{ .usage = .{ .protocol = protocol, .purpose = .normal, .value = .{ .input_tokens = 9000, .output_tokens = 1000, .cached_input_tokens = 8500, .reasoning_tokens = 800, .total_tokens = 17000 } } }, 2);
        try std.testing.expectEqual(@as(u64, 17000), state.context.?.tokens);
        state.observe(.{ .text = "more text" }, 3);
        state.observe(.{ .compacted = .{ .before = 80000, .after = 2000 } }, 4);
        try std.testing.expectEqual(@as(u64, 17000), state.context.?.tokens);
        state.observe(.{ .usage = .{ .protocol = protocol, .purpose = .summary, .value = .{ .input_tokens = 100, .output_tokens = 10, .cached_input_tokens = 80, .reasoning_tokens = 3 } } }, 5);
        try std.testing.expectEqual(@as(u64, 110), state.context.?.tokens);
        state.observe(.{ .usage = .{ .protocol = protocol, .purpose = .normal, .value = .{ .input_tokens = 100 } } }, 6);
        try std.testing.expect(!state.context.?.known);
        try std.testing.expect(contextRatio(state.context.?) == null);
        // Terminal cumulative billing is NOT a replacement for missing usage.
        state.finish(.{ .status = .failed, .usage = .{ .normal = .{ .total_tokens = 500000 } } });
        try std.testing.expect(!state.context.?.known);
        state.reset();
        try std.testing.expect(!state.context.?.known);
        state.observe(.{ .usage = .{ .protocol = protocol, .purpose = .normal, .value = .{ .total_tokens = 0 } } }, 9);
        try std.testing.expect(state.context.?.known);
        try std.testing.expectEqual(@as(?u128, 0), contextRatio(state.context.?));
        state.observe(.{ .usage = .{ .protocol = protocol, .purpose = .normal, .value = .{ .input_tokens = std.math.maxInt(u64), .output_tokens = 1 } } }, 10);
        try std.testing.expect(!state.context.?.known);
    }
}
