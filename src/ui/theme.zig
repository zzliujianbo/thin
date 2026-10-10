//! Shared warm-orange terminal palette. Only our renderer emits SGR;
//! model/user bytes are sanitized separately, never interpreted as escapes.
const activity = @import("../presentation/activity.zig");

pub const reset = "\x1b[0m";
pub const accent = "\x1b[38;5;208m";
pub const heading = "\x1b[1m\x1b[38;5;214m";
pub const strong = "\x1b[1m\x1b[38;5;215m";
pub const muted = "\x1b[38;5;245m";
pub const quote = "\x1b[38;5;180m";
pub const link = "\x1b[4m\x1b[38;5;75m";
pub const code = "\x1b[38;5;223m\x1b[48;5;235m";
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
        .none => muted,
        .minimal => "\x1b[38;5;117m",
        .low => success,
        .medium => caution,
        .high => "\x1b[38;5;75m",
        .xhigh => "\x1b[38;5;171m",
    };
}

/// Active tool prefix only; no blink/background and no animation after result.
pub const command_pulse = [_][]const u8{
    "\x1b[38;5;173m", "\x1b[38;5;208m", "\x1b[38;5;214m", "\x1b[38;5;220m",
    "\x1b[38;5;223m", "\x1b[38;5;220m", "\x1b[38;5;214m", "\x1b[38;5;208m",
};
