//! 终端动画适配；接收端计量和色流相位使用公开展示层，点阵/工具字形仅属 TUI。
const std = @import("std");
const shared = @import("../presentation.zig");
pub const Meter = shared.activity.Meter;
pub const Flow = shared.activity.Flow;
pub const Tool = shared.tools.Kind;

pub fn icon(kind: Tool) []const u8 {
    return switch (kind) {
        .memory => "▣",
        .bash => ">",
        .read => "≡",
        .write => "✎",
        .other => "⚙",
    };
}

/// 固定80ms，与 TPS 驱动的色流速度无关。
pub fn spinner(now_ms: u64) []const u8 {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    return frames[(now_ms / 80) % frames.len];
}

test "terminal spinner retains fixed80ms independent of shared TPS flow" {
    try std.testing.expect(!std.mem.eql(u8, spinner(0), spinner(80)));
    try std.testing.expectEqualStrings(spinner(0), spinner(800));
    try std.testing.expectEqualStrings("⠧", spinner(600));
    try std.testing.expect(Flow.interval(1000) < Flow.interval(100));
}
