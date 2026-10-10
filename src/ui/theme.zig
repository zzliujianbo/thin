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
