//! Focused POSIX filesystem tests, independent of terminal, SSH and worker IPC.
const filesystem = @import("platform/filesystem.zig");

test {
    _ = filesystem;
    _ = @import("app/auth_store.zig");
    _ = @import("app/resume_store.zig");
    _ = @import("tools/memory.zig");
    _ = @import("tests/filesystem_portability_test.zig");
}
