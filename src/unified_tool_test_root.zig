//! Focused offline Core/Bridge lifecycle validation; no app, config or network.
test {
    _ = @import("core/tool_stream.zig");
    _ = @import("tests/ui_bridge_test_root.zig");
    _ = @import("tests/runtime_test.zig");
    _ = @import("tests/tool_lifecycle_test.zig");
}
