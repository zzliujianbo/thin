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
