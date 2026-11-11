//! Linux keeps its existing authenticated SSH terminal transport. macOS local
//! mode never references these C symbols and cannot activate a remote terminal.
const builtin = @import("builtin");

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
