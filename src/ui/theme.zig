//! Shared warm-orange terminal palette. Only our renderer emits SGR;
//! model/user bytes are sanitized separately, never interpreted as escapes.
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
