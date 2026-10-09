//! 探针测试的汇总入口：通过 @import 引入各个 probe 文件，使其中的 test 被测试运行器编译并执行。
//! 这些探针是对 Linux I/O（本地 HTTP 服务、进程派生、PTY 终端）行为的黑盒验证。

// 引入所有探针；_ = 仅为触发引用，使其中的 test 声明被收集。
test {
    _ = @import("probes/basic.zig");
    _ = @import("probes/http.zig");
    _ = @import("probes/process.zig");
    _ = @import("probes/terminal.zig");
}
