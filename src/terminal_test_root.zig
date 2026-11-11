//! Local terminal/locale and wakeup tests; no worker, daemon or SSH on macOS.
test {
    _ = @import("platform/terminal_abi.zig");
    _ = @import("platform/wakeup.zig");
    _ = @import("ui/terminal.zig");
    _ = @import("ui/text.zig");
    _ = @import("ui/startup.zig");
}
