//! 正文语义分类，不包含标题颜色/Markdown/HTML，也不将显示标签写入协议正文。

const p = @import("../core/protocol.zig");

pub const Kind = enum { intermediate, final, incomplete };

/// 截断block列表不能证明没有tools；只有完整canonical列表可以标为final。
/// 文本字节被截断不等于block列表不完整。没有可见正文的占位记录由renderer移除。
pub fn classify(blocks: []const p.Block, blocks_complete: bool) Kind {
    for (blocks) |block| if (block == .tool_call) return .intermediate;
    return if (blocks_complete) .final else .incomplete;
}
