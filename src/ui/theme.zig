//! Keep yellow headings, blue links, purple inline/bullets and green code.
//! Use the 256-color cube for vivid yellow/green and a cooler violet, avoiding
//! the gray/red cast of theme-defined bright slots. Blue stays at slot 12.
//! No truecolor escapes, added bold, backgrounds or palette probing.
//! Only our renderer emits SGR;
//! model/user bytes are sanitized separately, never interpreted as escapes.
const activity = @import("../presentation/activity.zig");

pub const reset = "\x1b[0m";
pub const accent = "\x1b[38;5;208m";
pub const heading = "\x1b[1m\x1b[38;5;220m";
/// Bold terminal-default foreground, readable on light and dark themes.
pub const strong = "\x1b[1m";
pub const muted = "\x1b[38;5;245m";
pub const md_dim = "\x1b[39m\x1b[2m";
pub const quote = md_dim ++ "\x1b[3m";
pub const link = "\x1b[4m\x1b[38;5;12m";
/// Foreground only, even for fenced/indented code; no row background or padding.
pub const inline_code = "\x1b[38;5;141m";
pub const code = "\x1b[38;5;83m";
pub const table_header = "\x1b[1m";
pub const bullet = inline_code;
/// File-change counts are independent of Markdown brightness.
pub const diff_added = "\x1b[38;5;2m";
pub const diff_removed = "\x1b[38;5;1m";
pub const user = "\x1b[38;5;255m\x1b[48;2;52;36;24m";
pub const user_background = "\x1b[48;2;52;36;24m";

pub const success = "\x1b[38;5;114m";
pub const failure = "\x1b[38;5;203m";
pub const caution = "\x1b[38;5;214m";
/// Foreground only: the editor/background remain the terminal's defaults.
pub const model_flow = [_][]const u8{
    "\x1b[38;5;242m", "\x1b[38;5;246m", "\x1b[38;5;250m", "\x1b[38;5;255m",
    "\x1b[38;5;223m", "\x1b[38;5;215m", "\x1b[38;5;214m", "\x1b[38;5;208m",
    "\x1b[38;5;173m", "\x1b[38;5;137m", "\x1b[38;5;245m", "\x1b[38;5;243m",
};
pub const model_slow = [_][]const u8{
    "\x1b[38;5;167m", "\x1b[38;5;203m", "\x1b[38;5;204m", "\x1b[38;5;210m",
    "\x1b[38;5;217m", "\x1b[38;5;216m", "\x1b[38;5;209m", "\x1b[38;5;203m",
    "\x1b[38;5;198m", "\x1b[38;5;197m", "\x1b[38;5;196m", "\x1b[38;5;161m",
};
pub const model_fast = [_][]const u8{
    "\x1b[38;5;65m",  "\x1b[38;5;71m",  "\x1b[38;5;77m",  "\x1b[38;5;83m",
    "\x1b[38;5;119m", "\x1b[38;5;155m", "\x1b[38;5;194m", "\x1b[38;5;157m",
    "\x1b[38;5;120m", "\x1b[38;5;84m",  "\x1b[38;5;78m",  "\x1b[38;5;72m",
};

pub fn modelPalette(band: activity.RateBand) []const []const u8 {
    return switch (band) {
        .unknown, .standard => &model_flow,
        .slow => &model_slow,
        .fast => &model_fast,
    };
}

/// A configured request level. This does not claim provider-internal depth.
pub fn effortColor(effort: activity.ReasoningEffort) []const u8 {
    return switch (effort) {
        .unspecified, .unknown => reset,
        .off, .none => muted,
        .minimal => "\x1b[38;5;117m",
        .low => success,
        .medium => reset,
        .high => "\x1b[38;5;75m",
        .xhigh => "\x1b[38;5;171m",
        .max => "\x1b[38;5;177m", // Distinct brighter violet for maximum effort.
    };
}

/// Active tool prefix only; no blink/background and no animation after result.
pub const command_pulse = [_][]const u8{
    "\x1b[38;5;173m", "\x1b[38;5;208m", "\x1b[38;5;214m", "\x1b[38;5;220m",
    "\x1b[38;5;223m", "\x1b[38;5;220m", "\x1b[38;5;214m", "\x1b[38;5;208m",
};

test "Markdown uses vivid yellow green and cool violet without changing font styles" {
    const std = @import("std");
    const testing = std.testing;
    try testing.expectEqualStrings("\x1b[1m\x1b[38;5;220m", heading);
    try testing.expectEqualStrings("\x1b[4m\x1b[38;5;12m", link);
    try testing.expectEqualStrings("\x1b[38;5;141m", inline_code);
    try testing.expectEqualStrings("\x1b[38;5;83m", code);
    try testing.expectEqualStrings(inline_code, bullet);
    try testing.expectEqualStrings("\x1b[1m", strong);
    for ([_][]const u8{ heading, link, inline_code, code, bullet }) |style| {
        for ([_][]const u8{ "38;2;", "48;" }) |rejected| try testing.expect(std.mem.indexOf(u8, style, rejected) == null);
    }
    for ([_][]const u8{ link, inline_code, code, bullet }) |style| try testing.expect(std.mem.indexOf(u8, style, "\x1b[1m") == null);
    try testing.expectEqualStrings("\x1b[38;5;2m", diff_added);
    try testing.expectEqualStrings("\x1b[38;5;1m", diff_removed);
    try testing.expectEqualStrings(reset, effortColor(.medium));
    try testing.expectEqualStrings("\x1b[38;5;75m", effortColor(.high));
    try testing.expectEqualStrings("\x1b[38;5;171m", effortColor(.xhigh));
}
