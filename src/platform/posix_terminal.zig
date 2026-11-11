//! Narrow libc terminal constants absent or Linux-only in Zig 0.17 std.c.
//! Verified against target headers by tests/macos/terminal_abi_probe.c.
//! @cImport is unavailable in Zig 0.17; keep this small ABI surface explicit.
const std = @import("std");
const builtin = @import("builtin");

const darwin = builtin.os.tag == .macos;
comptime {
    if (!darwin and builtin.os.tag != .linux) @compileError("POSIX terminal backend requires Linux or macOS");
}

const C = struct {
    // libc ioctl takes unsigned long (Darwin and glibc), not std.c's c_int.
    extern "c" fn ioctl(c_int, c_ulong, ...) c_int;
    extern "c" fn tcflow(c_int, c_int) c_int;
    extern "c" fn setlocale(c_int, ?[*:0]const u8) ?[*:0]const u8;
};

pub const get_window: c_ulong = if (darwin) 0x40087468 else std.os.linux.T.IOCGWINSZ;
pub const set_window: c_ulong = if (darwin) 0x80087467 else std.os.linux.T.IOCSWINSZ;
pub const output_off: c_int = if (darwin) 1 else 0;
pub const output_on: c_int = if (darwin) 2 else 1;
pub const locale_ctype: c_int = if (darwin) 2 else 0;
pub const locale_numeric: c_int = if (darwin) 4 else 1;

/// Darwin exposes kernel-owned FWASWRITTEN (bsd/sys/fcntl.h) in F_GETFL
/// after the first write. F_SETFL cannot undo that history bit. Compare only
/// configuration, retaining every other bit including NONBLOCK and APPEND.
pub fn configuredFileFlags(value: c_int) c_int {
    return if (darwin) value & ~@as(c_int, 0x00010000) else value;
}

pub fn getSize(fd: c_int, value: *std.c.winsize) c_int {
    return C.ioctl(fd, get_window, value);
}

pub fn setSize(fd: c_int, value: *const std.c.winsize) c_int {
    return C.ioctl(fd, set_window, value);
}

pub fn pauseOutput(fd: c_int, paused: bool) c_int {
    return C.tcflow(fd, if (paused) output_off else output_on);
}

/// Only CTYPE changes. Never use the pinned std.c.LC enum on Darwin: it has
/// Linux values, so .CTYPE=0 would accidentally select Darwin LC_ALL.
pub fn setCtype(locale: [*:0]const u8) bool {
    return C.setlocale(locale_ctype, locale) != null;
}

/// Borrowed until the next locale change; used only at startup / in serial tests.
pub fn numericLocale() ?[*:0]const u8 {
    return C.setlocale(locale_numeric, null);
}
