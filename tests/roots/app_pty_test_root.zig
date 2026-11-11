//! Standalone application acceptance driver, not a library unit-test root.
//! zig build-exe src/app_pty_test_root.zig -lc -lutil -femit-bin=/tmp/thin-app-pty

/// 入口函数实际定义在 tests/app_pty_test.zig，这里仅转发，供独立可执行文件使用。
pub const main = @import("tests/app_pty_test.zig").main;
