//! Focused platform invariants without importing App, TTY or worker IPC.
const std = @import("std");
const fs = @import("../platform/filesystem.zig");
const context = @import("../core/session_context.zig");
const t = std.testing;

fn rootFor(dir: std.Io.Dir) !fs.Root {
    var path: [4096]u8 = undefined;
    const length = try dir.realPath(t.io, &path);
    return fs.Root.open(t.allocator, t.io, path[0..length]);
}

fn openFile(parent: c_int, name: [*:0]const u8) !c_int {
    const fd = fs.openAt(parent, name, .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
    if (fd < 0) return fs.osError();
    return fd;
}
