//! 前端共享的接收端计量与连续动画相位。无终端颜色、字符宽度或帧状态。
//! Renderer-independent animation and receive-rate display. It makes no cumulative
//! or provider-derived claim: the only measurement is a rolling ~TPS window over
//! received visible text/arguments of the current call. Tool and idle gaps are
//! dropped because a new call restarts its own window; all clocks are supplied
//! so the window stays deterministic in tests.
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
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
    max,
    unknown,

    pub fn fromName(configured: ?[]const u8) ReasoningEffort {
        const value = configured orelse return .unspecified;
        inline for (.{ "off", "minimal", "low", "medium", "high", "xhigh", "max" }) |known| {
            if (std.mem.eql(u8, value, known)) return @field(ReasoningEffort, known);
        }
        return .unknown;
    }

    pub fn name(self: ReasoningEffort) ?[]const u8 {
        return switch (self) {
            .unspecified, .unknown => null,
            .off => "off",
            .minimal => "minimal",
            .low => "low",
            .medium => "medium",
            .high => "high",
            .xhigh => "xhigh",
            .max => "max",
        };
    }
};

/// Canonical order is shared by capability selection and Pi-style clamping.
pub const effort_order = [_]ReasoningEffort{ .off, .minimal, .low, .medium, .high, .xhigh, .max };
pub const EffortSet = struct {
    mask: u8 = 0,

    pub fn contains(self: EffortSet, effort: ReasoningEffort) bool {
        for (effort_order, 0..) |level, i| {
            if (level == effort) return self.mask & (@as(u8, 1) << @intCast(i)) != 0;
        }
        return false;
    }
    pub fn first(self: EffortSet) ?ReasoningEffort {
        for (effort_order) |level| if (self.contains(level)) return level;
        return null;
    }
    pub fn count(self: EffortSet) usize {
        return @popCount(self.mask & 0x7f);
    }
    pub fn next(self: EffortSet, current: ReasoningEffort) ?ReasoningEffort {
        for (effort_order, 0..) |level, i| {
            if (level == current) {
                for (1..effort_order.len + 1) |delta| {
                    const candidate = effort_order[(i + delta) % effort_order.len];
                    if (self.contains(candidate)) return candidate;
                }
                return null;
            }
        }
        // A known set can start from an unspecified/custom current option.
        // This is an explicit user choice; startup itself still emits no level.
        return self.first();
    }
    /// Prefer the next stronger supported level, then the nearest weaker one.
    pub fn clamp(self: EffortSet, requested: ReasoningEffort) ?ReasoningEffort {
        for (effort_order, 0..) |level, i| {
            if (level == requested) {
                for (effort_order[i..]) |candidate| if (self.contains(candidate)) return candidate;
                var n = i;
                while (n > 0) {
                    n -= 1;
                    if (self.contains(effort_order[n])) return effort_order[n];
                }
                return null;
            }
        }
        return null;
    }
};

test "effort sets reject old names bounded cycle and upward first clamp" {
    const t = std.testing;
    const set: EffortSet = .{ .mask = 1 | 4 | 16 | 64 };
    try t.expectEqual(ReasoningEffort.unknown, ReasoningEffort.fromName("none"));
    try t.expect(!@hasField(ReasoningEffort, "none"));
    try t.expectEqualStrings("off", ReasoningEffort.off.name().?);
    try t.expect(set.contains(.off));
    try t.expectEqual(@as(usize, 4), set.count());
    try t.expectEqual(ReasoningEffort.low, set.next(.off).?);
    try t.expectEqual(ReasoningEffort.off, set.next(.max).?);
    try t.expectEqual(ReasoningEffort.high, set.clamp(.medium).?);
    try t.expectEqual(ReasoningEffort.max, set.clamp(.xhigh).?);
    try t.expectEqual(ReasoningEffort.high, (EffortSet{ .mask = 16 }).clamp(.max).?);
    try t.expectEqual(ReasoningEffort.high, (EffortSet{ .mask = 16 }).next(.high).?);
    try t.expect((EffortSet{}).next(.high) == null);
    try t.expect((EffortSet{}).first() == null);
    try t.expect(set.clamp(.unknown) == null);
    try t.expectEqual(ReasoningEffort.off, set.next(.unknown).?);
    try t.expectEqual(ReasoningEffort.off, set.next(.unspecified).?);
    try t.expect((EffortSet{}).next(.unspecified) == null);
    // Every canonical subset: clamping picks upward first, cycling remains in
    // the declared set and wraps in exactly count() supported transitions.
    for (0..128) |bits| {
        const subset: EffortSet = .{ .mask = @intCast(bits) };
        for (effort_order, 0..) |requested, i| {
            var expected: ?ReasoningEffort = null;
            for (effort_order[i..]) |candidate| {
                if (subset.contains(candidate)) {
                    expected = candidate;
                    break;
                }
            }
            if (expected == null) {
                var n = i;
                while (n > 0) {
                    n -= 1;
                    if (subset.contains(effort_order[n])) {
                        expected = effort_order[n];
                        break;
                    }
                }
            }
            try t.expectEqual(expected, subset.clamp(requested));
            if (subset.contains(requested)) {
                var current = requested;
                for (0..subset.count()) |_| {
                    current = subset.next(current).?;
                    try t.expect(subset.contains(current));
                }
                try t.expectEqual(requested, current);
            }
        }
    }
}

/// Renderer-independent execution pulse; only active tool presentation uses it.
pub fn commandStep(now_ms: u64) usize {
    return @intCast((now_ms / 120) % 8);
}

/// Observed wall-clock execution time for one command row. Always a measurement
/// of the same monotonic clock passed by the caller; never an estimate. Values
/// below one second retain milliseconds; longer times use seconds/minutes.
pub fn formatDuration(writer: *std.Io.Writer, ms: u64) !void {
    if (ms < 1000) {
        try writer.print("{d}ms", .{ms});
    } else if (ms < 10_000) {
        try writer.print("{d}.{d:0>2}s", .{ ms / 1000, (ms % 1000) / 10 });
    } else if (ms < 60_000) {
        try writer.print("{d}.{d}s", .{ ms / 1000, (ms % 1000) / 100 });
    } else {
        try writer.print("{d}m{d:0>2}s", .{ ms / 60_000, (ms % 60_000) / 1000 });
    }
}

test "command duration keeps sub-second precision and rolls up past a minute" {
    const cases = [_]struct { ms: u64, expected: []const u8 }{
        .{ .ms = 0, .expected = "0ms" },
        .{ .ms = 7, .expected = "7ms" },
        .{ .ms = 420, .expected = "420ms" },
        .{ .ms = 999, .expected = "999ms" },
        .{ .ms = 1000, .expected = "1.00s" },
        .{ .ms = 9999, .expected = "9.99s" },
        .{ .ms = 12_300, .expected = "12.3s" },
        .{ .ms = 59_999, .expected = "59.9s" },
        .{ .ms = 60_000, .expected = "1m00s" },
        .{ .ms = 125_400, .expected = "2m05s" },
    };
    for (cases) |case| {
        var buffer: [16]u8 = undefined;
        var stream = std.Io.Writer.fixed(&buffer);
        try formatDuration(&stream, case.ms);
        try std.testing.expectEqualStrings(case.expected, stream.buffered());
    }
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

/// Only the live window is measured: whether a call is open, its first received
/// delta and the recent buckets those deltas landed in.
pub const Meter = struct {
    call_active: bool = false,
    first_received_ms: ?u64 = null,
    buckets: [10]Bucket = @splat(.{}),

    pub fn reset(self: *Meter) void {
        self.* = .{};
    }

    pub fn beginCall(self: *Meter) void {
        self.* = .{ .call_active = true };
    }

    pub fn endCall(self: *Meter) void {
        self.call_active = false;
    }

    /// Count UTF-8 leading bytes rather than rounding each transport delta.
    /// Chunk boundaries (even inside a codepoint) must not multiply estimates.
    pub fn observe(self: *Meter, now_ms: u64, bytes: []const u8) void {
        if (!self.call_active) return;
        if (bytes.len == 0) return;
        if (self.first_received_ms == null) self.first_received_ms = now_ms;
        var counts: Counts = .{};
        for (bytes) |byte| {
            if (byte < 128) counts.ascii += 1 else if (byte & 0xc0 != 0x80) counts.unicode += 1;
        }
        const tick = now_ms / 100;
        const bucket = &self.buckets[tick % self.buckets.len];
        if (bucket.tick != tick) bucket.* = .{ .tick = tick };
        bucket.counts.add(counts);
    }

    /// Rate in tenths of tokens/s. A short window is unknown, not a spike.
    pub fn liveRate(self: *const Meter, now_ms: u64) ?u64 {
        if (!self.call_active) return null;
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
    inline for (.{ "off", "minimal", "low", "medium", "high", "xhigh", "max" }) |name| {
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

test "live rate does not depend on delta or UTF8 boundaries" {
    var together: Meter = .{};
    together.beginCall();
    together.observe(100, "abcd你");
    var split: Meter = .{};
    split.beginCall();
    for ("abcd你") |byte| split.observe(100, &.{byte});
    // (4 ascii + 2) / 3 + 1 wide codepoint * 2 = 4 tokens over the 500ms window.
    try std.testing.expectEqual(@as(?u64, 80), together.liveRate(600));
    try std.testing.expectEqual(together.liveRate(600), split.liveRate(600));
}

test "rolling TPS becomes zero after idle and cannot invent a short window rate" {
    var m: Meter = .{};
    m.beginCall();
    m.observe(0, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try std.testing.expect(m.liveRate(200) == null);
    try std.testing.expectEqual(@as(?u64, 400), m.liveRate(250));
    try std.testing.expectEqual(@as(?u64, 0), m.liveRate(1100));
    m.endCall();
    try std.testing.expect(m.liveRate(1300) == null);
}

test "live rate excludes tool gaps new requests and finished or reset state" {
    var m: Meter = .{};
    m.beginCall();
    m.observe(1000, "abc"); // One token inside a 500ms window.
    try std.testing.expectEqual(@as(?u64, 20), m.liveRate(1500));
    m.endCall();
    try std.testing.expect(m.liveRate(1600) == null);
    // Six idle/tool seconds are not generation time: the next request opens its
    // own window instead of inheriting the gap or the previous buckets.
    m.beginCall();
    m.observe(7000, "aaaaaa"); // Two tokens, nothing carried over.
    try std.testing.expectEqual(@as(?u64, 40), m.liveRate(7500));
    m.reset();
    try std.testing.expect(m.liveRate(7600) == null);
    try std.testing.expect(rate(1, 0) == null);
}
