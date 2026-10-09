//! 编译器冒烟探针：仅导出一个 C ABI 函数，不依赖 std.Io、libc、测试运行器或 build.zig，用于单独验证目标代码生成是否正常。

// Isolates object-code generation from std.Io, libc, the test runner and build.zig.
// 导出给 C 调用的符号；返回固定值 42，测试只需确认该符号可以被正确生成和调用。
export fn thin_probe_compiler_smoke() u32 {
    return 42;
}
