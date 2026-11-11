test {
    // 引入实际的 HTTP 集成测试；测试需要 build.zig 中由 Node 启动的本地 mock 服务。
    _ = @import("tests/http_integration_test.zig");
}
