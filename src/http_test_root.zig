//! HTTP/SSE 集成测试的测试根文件，仅作为 test 块的容器，不包含业务逻辑。

// 本地 HTTP/SSE 集成测试的测试根。
// 由 build.zig 的 test-http 步骤编译，模块根位于 src/，因此可以引用 src/ 下的全部模块。
test {
    // 引入实际的 HTTP 集成测试；测试需要 build.zig 中由 Node 启动的本地 mock 服务。
    _ = @import("tests/http_integration_test.zig");
}
