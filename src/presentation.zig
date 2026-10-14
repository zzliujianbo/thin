//! 公共、前端无关的展示入口。TUI与未来Web宿主共享结构化工具信息、文件观察、
//! canonical正文分类、当前ctx和接收端TPS状态；不要复用终端ANSI输出作为Web内容。
//! Call/Queue持有有界文本，deinit释放；State仅持有数字，无借用Runtime历史。
//! 模块不依赖ui/、libc宽度、MD4C、TTY或存储。Web需另做transport/component/HTML转义。
pub const tools = @import("presentation/tools.zig");
pub const answer = @import("presentation/answer.zig");
pub const activity = @import("presentation/activity.zig");
pub const state = @import("presentation/state.zig");
pub const failure = @import("presentation/failure.zig");
pub const State = state.State;
pub const View = state.View;
pub const ContextSnapshot = state.ContextSnapshot;
pub const ReasoningEffort = activity.ReasoningEffort;
pub const FileStats = tools.FileStats;

test {
    _ = tools;
    _ = answer;
    _ = activity;
    _ = state;
    _ = failure;
}
