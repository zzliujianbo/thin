//! 前端共享的接收端计量与连续动画相位。无终端颜色、字符宽度或帧状态。
//! Renderer-independent animation and throughput. No tokenizer or provider timing claim:
//! rolling ~TPS estimates received visible text/arguments; final TPS uses reported
//! output divided by client-observed normal request time (including TTFT). Tool
//! and summary time are excluded. All clocks are supplied for deterministic tests.
const std = @import("std");

/// UI bands, not provider performance grades. Unknown is not a slow/zero rate.
pub const RateBand = enum { unknown, slow, standard, fast };
pub fn rateBand(tenths: ?u64) RateBand {
    const value = tenths orelse return .unknown;
    return if (value < 200) .slow else if (value >= 800) .fast else .standard;
}

/// Configured request option, not measured cognitive depth or proof that a
/// provider honored the option. Unknown/custom values never guess a level.
pub const ReasoningEffort = enum {
    unspecified,
    none,
    minimal,
    low,
    medium,
    high,
    xhigh,
    unknown,

    pub fn fromName(configured: ?[]const u8) ReasoningEffort {
        const value = configured orelse return .unspecified;
        inline for (.{ "none", "minimal", "low", "medium", "high", "xhigh" }) |known| {
            if (std.mem.eql(u8, value, known)) return @field(ReasoningEffort, known);
        }
        return .unknown;
    }

    /// Request-option cycle only; no provider capability or hidden-depth claim.
    pub fn next(self: ReasoningEffort) ReasoningEffort {
        return switch (self) {
            .unspecified, .unknown, .xhigh => .none,
            .none => .minimal,
            .minimal => .low,
            .low => .medium,
            .medium => .high,
            .high => .xhigh,
        };
    }
    pub fn name(self: ReasoningEffort) ?[]const u8 {
        return switch (self) {
            .unspecified, .unknown => null,
            .none => "none",
            .minimal => "minimal",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh => "xhigh",
        };
    }
};

test "request effort cycle is explicit wraps and never guesses custom levels" {
    var effort: ReasoningEffort = .none;
    for ([_]ReasoningEffort{ .minimal, .low, .medium, .high, .xhigh, .none }) |expected| {
        effort = effort.next();
        try std.testing.expectEqual(expected, effort);
        try std.testing.expectEqual(effort, ReasoningEffort.fromName(effort.name()));
    }
    try std.testing.expectEqual(ReasoningEffort.none, ReasoningEffort.unspecified.next());
    try std.testing.expectEqual(ReasoningEffort.none, ReasoningEffort.unknown.next());
    try std.testing.expectEqual(@as(?[]const u8, null), ReasoningEffort.unknown.name());
}

/// Renderer-independent execution pulse; only active tool presentation uses it.
pub fn commandStep(now_ms: u64) usize {
    return @intCast((now_ms / 120) % 8);
}

/// Continuous UI-owned phase, not absolute now/rate: speed changes must not
/// jump the highlight backwards. Unknown TPS uses a quiet baseline, never a
/// fabricated rate. A bounded catch-up prevents suspend/clock jumps flashing.
pub const Flow = struct {
    last_ms: ?u64 = null,
    units: u64 = 0,

    pub fn interval(tenths: ?u64) u64 {
        const value = tenths orelse return 300;
        const bounded: u64 = @min(value, 2000);
        return @max(40, @as(u64, 300000) / (1000 + bounded * 3));
    }

    pub fn advance(self: *Flow, now_ms: u64, active: bool, tenths: ?u64) void {
        const before = self.last_ms;
        self.last_ms = now_ms;
        if (!active) {
            self.units = 0;
            return;
        }
        const delta: u64 = @min(@as(u64, 1000), now_ms -| (before orelse now_ms));
        self.units = (self.units + delta * 1000 / interval(tenths)) % 12000;
    }

    pub fn step(self: Flow) usize {
        return @intCast(self.units / 1000);
    }
};

const Counts = struct {
    ascii: u64 = 0,
    unicode: u64 = 0,
    valid: bool = true,

    fn add(self: *Counts, value: Counts) void {
        const a = @addWithOverflow(self.ascii, value.ascii);
        const u = @addWithOverflow(self.unicode, value.unicode);
        self.valid = self.valid and value.valid and a[1] == 0 and u[1] == 0;
        self.ascii = a[0];
        self.unicode = u[0];
    }

    fn estimate(self: Counts) ?u64 {
        if (!self.valid) return null;
        const n = (@as(u128, self.ascii) + 2) / 3 + @as(u128, self.unicode) * 2;
        return if (n <= std.math.maxInt(u64)) @intCast(n) else null;
    }
};

const Bucket = struct { tick: ?u64 = null, counts: Counts = .{} };

pub const Meter = struct {
    started_ms: ?u64 = null,
    finished_ms: ?u64 = null,
    call_started_ms: ?u64 = null,
    first_received_ms: ?u64 = null,
    ttft_ms: ?u64 = null,
    normal_ms: u64 = 0,
    timing_valid: bool = true,
    total: Counts = .{},
    has_received: bool = false,
    buckets: [10]Bucket = @splat(.{}),

    pub fn reset(self: *Meter, now_ms: u64) void {
        self.* = .{ .started_ms = now_ms };
    }

    pub fn beginCall(self: *Meter, now_ms: u64) void {
        self.endCall(now_ms);
        self.call_started_ms = now_ms;
        self.first_received_ms = null;
        self.ttft_ms = null;
        self.buckets = @splat(.{});
    }

    pub fn endCall(self: *Meter, now_ms: u64) void {
        if (self.call_started_ms) |start| {
            const n = @addWithOverflow(self.normal_ms, now_ms -| start);
            self.timing_valid = self.timing_valid and now_ms >= start and n[1] == 0;
            self.normal_ms = n[0];
            self.call_started_ms = null;
        }
    }

    pub fn finish(self: *Meter, now_ms: u64) void {
        self.endCall(now_ms);
        self.finished_ms = now_ms;
    }

    /// Count UTF-8 leading bytes rather than rounding each transport delta.
    /// Chunk boundaries (even inside a codepoint) must not multiply estimates.
    pub fn observe(self: *Meter, now_ms: u64, bytes: []const u8) void {
        const start = self.call_started_ms orelse return;
        if (bytes.len == 0) return;
        if (self.first_received_ms == null) {
            self.first_received_ms = now_ms;
            self.ttft_ms = now_ms -| start;
        }
        var counts: Counts = .{};
        for (bytes) |byte| {
            if (byte < 128) counts.ascii += 1 else if (byte & 0xc0 != 0x80) counts.unicode += 1;
        }
        self.total.add(counts);
        self.has_received = true;
        const tick = now_ms / 100;
        const bucket = &self.buckets[tick % self.buckets.len];
        if (bucket.tick != tick) bucket.* = .{ .tick = tick };
        bucket.counts.add(counts);
    }

    /// Rate in tenths of tokens/s. A short window is unknown, not a spike.
    pub fn liveRate(self: *const Meter, now_ms: u64) ?u64 {
        if (self.call_started_ms == null) return null;
        const first = self.first_received_ms orelse return null;
        const window_ms = @min(@as(u64, 1000), now_ms -| first);
        if (window_ms < 250) return null;
        const tick = now_ms / 100;
        var counts: Counts = .{};
        for (self.buckets) |bucket| {
            const at = bucket.tick orelse continue;
            if (at <= tick and tick - at < self.buckets.len) counts.add(bucket.counts);
        }
        return rate(counts.estimate(), window_ms);
    }

    pub fn average(self: *const Meter, reported_output: ?u64) ?u64 {
        if (!self.timing_valid) return null;
        return rate(reported_output, self.normal_ms);
    }

    pub fn estimatedAverage(self: *const Meter) ?u64 {
        if (!self.has_received) return null;
        return self.average(self.total.estimate());
    }

    pub fn elapsed(self: *const Meter, now_ms: u64) ?u64 {
        const start = self.started_ms orelse return null;
        return (self.finished_ms orelse now_ms) -| start;
    }
};

fn rate(tokens: ?u64, ms: u64) ?u64 {
    const n = tokens orelse return null;
    if (ms == 0) return null;
    return @intCast(@min(@as(u128, n) * 10000 / ms, std.math.maxInt(u64)));
}

test "rate bands and configured effort have explicit unknown and stable mapping" {
    try std.testing.expectEqual(RateBand.unknown, rateBand(null));
    try std.testing.expectEqual(RateBand.slow, rateBand(0));
    try std.testing.expectEqual(RateBand.slow, rateBand(199));
    try std.testing.expectEqual(RateBand.standard, rateBand(200));
    try std.testing.expectEqual(RateBand.standard, rateBand(799));
    try std.testing.expectEqual(RateBand.fast, rateBand(800));
    try std.testing.expectEqual(RateBand.fast, rateBand(std.math.maxInt(u64)));
    try std.testing.expectEqual(ReasoningEffort.unspecified, ReasoningEffort.fromName(null));
    try std.testing.expectEqual(ReasoningEffort.unknown, ReasoningEffort.fromName("provider-custom"));
    try std.testing.expectEqual(ReasoningEffort.unknown, ReasoningEffort.fromName("HIGH"));
    inline for (.{ "none", "minimal", "low", "medium", "high", "xhigh" }) |name| {
        try std.testing.expectEqual(@field(ReasoningEffort, name), ReasoningEffort.fromName(name));
    }
    try std.testing.expect(commandStep(0) != commandStep(120));
    try std.testing.expectEqual(commandStep(0), commandStep(960));
    try std.testing.expect(commandStep(std.math.maxInt(u64)) < 8);
}

test "model flow speeds up with TPS without backwards rate-change jumps" {
    try std.testing.expect(Flow.interval(1000) < Flow.interval(100));
    try std.testing.expectEqual(@as(u64, 300), Flow.interval(null));
    try std.testing.expect(Flow.interval(std.math.maxInt(u64)) >= 40);
    var slow: Flow = .{};
    var fast: Flow = .{};
    slow.advance(0, true, 100);
    fast.advance(0, true, 1000);
    slow.advance(600, true, 100);
    fast.advance(600, true, 1000);
    try std.testing.expect(fast.units > slow.units);
    const old = slow.units;
    slow.advance(600, true, 1000);
    try std.testing.expectEqual(old, slow.units);
    slow.advance(500, true, 0); // Clock regression never reverses a phase.
    try std.testing.expectEqual(old, slow.units);
    fast.advance(650, false, null);
    try std.testing.expectEqual(@as(u64, 0), fast.units);
}

test "stream estimate does not depend on delta or UTF8 boundaries" {
    var together: Meter = .{};
    together.reset(0);
    together.beginCall(100);
    together.observe(100, "abcd你");
    var split: Meter = .{};
    split.reset(0);
    split.beginCall(100);
    for ("abcd你") |byte| split.observe(100, &.{byte});
    try std.testing.expectEqual(together.total.estimate(), split.total.estimate());
    try std.testing.expectEqual(@as(?u64, 4), together.total.estimate());
    try std.testing.expectEqual(together.liveRate(600), split.liveRate(600));
}

test "rolling TPS becomes zero after idle and cannot invent a short window rate" {
    var m: Meter = .{};
    m.beginCall(0);
    m.observe(0, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try std.testing.expect(m.liveRate(200) == null);
    try std.testing.expectEqual(@as(?u64, 400), m.liveRate(250));
    try std.testing.expectEqual(@as(?u64, 0), m.liveRate(1100));
    m.endCall(1200);
    try std.testing.expect(m.liveRate(1300) == null);
}

test "normal call averages exclude tool gaps and keep unknown usage unknown" {
    var m: Meter = .{};
    m.reset(0);
    m.beginCall(100);
    m.observe(250, "visible");
    try std.testing.expectEqual(@as(?u64, 150), m.ttft_ms);
    m.endCall(1100);
    m.beginCall(6100); // Five seconds executing a tool are not generation time.
    m.endCall(7100);
    m.finish(7500);
    try std.testing.expectEqual(@as(u64, 2000), m.normal_ms);
    try std.testing.expectEqual(@as(?u64, 200), m.average(40));
    try std.testing.expect(m.average(null) == null);
    try std.testing.expectEqual(@as(?u64, 7500), m.elapsed(9000));
    try std.testing.expect(rate(1, 0) == null);
    var final_only: Meter = .{};
    final_only.beginCall(0);
    final_only.finish(1000);
    try std.testing.expect(final_only.estimatedAverage() == null);
    try std.testing.expectEqual(@as(?u64, 200), final_only.average(20));
}
