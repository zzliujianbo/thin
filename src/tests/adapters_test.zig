//! 适配器测试入口：通过引用各适配器的测试文件，让 zig build test 一并执行它们。

// 引入 chat 与 responses 适配器的测试。
test {
    _ = @import("../llm/chat.zig");
    _ = @import("../llm/responses.zig");
}
