//! Linux keeps its existing authenticated SSH terminal transport. macOS local
//! mode never references these C symbols and cannot activate a remote terminal.
const builtin = @import("builtin");
const std = @import("std");

pub const enabled = builtin.os.tag == .linux;

const Linux = struct {
    extern "c" fn thin_ssh_active() c_int;
    extern "c" fn thin_ssh_read([*]u8, usize) isize;
    extern "c" fn thin_ssh_write([*]const u8, usize) isize;
    extern "c" fn thin_ssh_wait(c_int, c_int) c_int;
    extern "c" fn thin_ssh_notification_fd(c_int) c_int;
    extern "c" fn thin_ssh_size(*c_uint, *c_uint) void;
};

pub fn active() bool {
    return if (enabled) Linux.thin_ssh_active() == 1 else false;
}

pub fn read(bytes: [*]u8, length: usize) isize {
    return if (enabled) Linux.thin_ssh_read(bytes, length) else -1;
}

pub fn write(bytes: [*]const u8, length: usize) isize {
    return if (enabled) Linux.thin_ssh_write(bytes, length) else -1;
}

pub fn wait(want_write: c_int, milliseconds: c_int) c_int {
    return if (enabled) Linux.thin_ssh_wait(want_write, milliseconds) else -1;
}

pub fn notificationFd(fd: c_int) c_int {
    return if (enabled) Linux.thin_ssh_notification_fd(fd) else -1;
}

pub fn size(columns: *c_uint, rows: *c_uint) void {
    if (enabled) {
        Linux.thin_ssh_size(columns, rows);
    } else {
        columns.* = 0;
        rows.* = 0;
    }
}

test "macOS remote terminal is unavailable without C SSH symbols or side effects" {
    if (comptime enabled) return error.SkipZigTest;
    try std.testing.expect(!active());
    var bytes: [8]u8 = @splat(42);
    try std.testing.expectEqual(@as(isize, -1), read(&bytes, bytes.len));
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(42)), &bytes);
    try std.testing.expectEqual(@as(isize, -1), write(&bytes, bytes.len));
    try std.testing.expectEqual(@as(c_int, -1), wait(0, 0));
    try std.testing.expectEqual(@as(c_int, -1), notificationFd(-1));
    var columns: c_uint = 80;
    var rows: c_uint = 24;
    size(&columns, &rows);
    try std.testing.expectEqual(@as(c_uint, 0), columns);
    try std.testing.expectEqual(@as(c_uint, 0), rows);
}
