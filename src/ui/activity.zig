//! 终端动画适配；接收端计量和色流相位使用公开展示层，点阵/工具字形仅属 TUI。

const shared = @import("../presentation.zig");
pub const Meter = shared.activity.Meter;
pub const Flow = shared.activity.Flow;
pub const Tool = shared.tools.Kind;

/// Tool name shown after the one-column status slot. It never changes between
/// the running and settled row, so the command column stays put.
pub fn toolName(kind: Tool) []const u8 {
    return switch (kind) {
        .memory => "memory",
        .bash => "bash",
        .read => "read_file",
        .write => "write_file",
        .edit => "edit_file",
        .subagent => "subagent",
        .subagent_id => "subagent",
        .parent_message => "message_parent",
        .other => "tool",
    };
}

/// 固定80ms，与 TPS 驱动的色流速度无关。
pub fn spinner(now_ms: u64) []const u8 {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    return frames[(now_ms / 80) % frames.len];
}
