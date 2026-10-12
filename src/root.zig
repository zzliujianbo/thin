//! 产品库的根模块：集中再导出各子系统，并在 test 块中引用所有需要参与单元测试的文件。

/// 协议类型（消息、事件、取消令牌等）。
pub const protocol = @import("core/protocol.zig");
/// JSON 辅助工具。
pub const json = @import("util/json.zig");
/// SSE（Server-Sent Events）流解析。
pub const sse = @import("llm/sse.zig");
/// LLM 公共层入口。
pub const llm = @import("llm/llm.zig");

/// 配置加载与 API key 解析。
pub const config = @import("core/config.zig");
/// 上下文预算估算与压缩计划（token 估算、切分边界）。
pub const context = @import("core/context.zig");
/// Agent 运行时：驱动模型调用、工具执行与事件分发。
pub const runtime = @import("core/runtime.zig");

/// HTTP 客户端。
pub const http = @import("llm/http.zig");
/// Chat Completions 协议适配。
pub const chat = @import("llm/chat.zig");
/// Responses 协议适配。
pub const responses = @import("llm/responses.zig");

/// 子进程管理平台层。
pub const process = @import("platform/process.zig");
/// 文件系统平台层。
pub const filesystem = @import("platform/filesystem.zig");

/// 项目记忆存储。
pub const memory = @import("tools/memory.zig");
/// 工具集合与分发。
pub const tools = @import("tools/tools.zig");

/// 前端共享展示数据/状态；不包含终端帧或权限决策。
pub const presentation = @import("presentation.zig");

// 引用各模块以便 `zig build test-unit` 编译并运行它们的测试；
// 集成测试与 UI 测试也在此统一挂载（build.zig 的 test-unit 步骤声明为离线运行，不需要网络或凭据）。
test {
    _ = protocol;
    _ = json;
    _ = sse;
    _ = llm;
    _ = config;
    _ = context;
    _ = runtime;
    _ = http;
    _ = chat;
    _ = responses;
    _ = process;
    _ = filesystem;
    _ = memory;
    _ = tools;
    _ = presentation;

    _ = @import("tests/tools_integration_test.zig");
    _ = @import("tests/headless_integration_test.zig");

    _ = @import("app/cli.zig");
    _ = @import("app/auth_store.zig");
    _ = @import("app/log_store.zig");
    _ = @import("app/journal.zig");
    _ = @import("app/session.zig");
    _ = @import("tests/settings_session_test.zig");
    _ = @import("tests/thinking_contract_test.zig");
    _ = @import("tests/context_usage_test.zig");
    _ = @import("ui/terminal.zig");
    _ = @import("ui/input.zig");
    _ = @import("ui/markdown.zig");
    _ = @import("ui/tail_frame.zig");
    _ = @import("tests/markdown_colors_test.zig");
    _ = @import("ui/bridge.zig");
    _ = @import("tests/ui_bridge_test_root.zig");
    _ = @import("tests/regular_screen.zig");
    _ = @import("ui/tui.zig");

    _ = @import("tests/runtime_test.zig");
    _ = @import("tests/adapter_integration_test.zig");
}
