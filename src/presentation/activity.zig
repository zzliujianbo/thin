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

    /// True from the first received delta until the call ends. Inter-chunk gaps
    /// keep counting as output; waiting for the first token, running tools and a
    /// finished call do not.
    pub fn streaming(self: *const Meter) bool {
        return self.call_active and self.first_received_ms != null;
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
