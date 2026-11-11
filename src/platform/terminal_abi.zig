//! libc terminal ABI: keep the explicit Linux x86_64 glibc layout because
//! Zig 0.17 std.c.termios aliases the smaller Linux kernel layout. Darwin uses
//! its separate std.c.termios layout. Neither is a direct kernel TCGETS struct.
//! Layout constants are also checked against libc headers by the C SDK probe.

const std = @import("std");
const builtin = @import("builtin");

pub const Termios = switch (builtin.os.tag) {
    .linux => GlibcTermios,
    .macos => std.c.termios,
    else => @compileError("Terminal ABI supports Linux x86_64 and macOS only"),
};

/// glibc's public struct (60 bytes, NCCS=32), NOT the Linux kernel layout.
const GlibcTermios = extern struct {
    /// 输入模式标志。
    iflag: std.c.tc_iflag_t,
    /// 输出模式标志。
    oflag: std.c.tc_oflag_t,
    /// 控制模式标志。
    cflag: std.c.tc_cflag_t,
    /// 本地模式标志（回显、规范模式、信号字符等）。
    lflag: std.c.tc_lflag_t,
    /// 线路规程，通常为 0。
    line: u8,
    /// 控制字符数组（如 VINTR、VEOF），glibc 使用 32 项；内核 termios 只有 19 项，二者不能混用。
    cc: [32]u8,
    /// 输入波特率。
    ispeed: c_uint,
    /// 输出波特率。
    ospeed: c_uint,
};

// 编译期校验布局：平台不对或偏移/大小不符时直接编译失败，避免 libc 写入时越界破坏内存。
comptime {
    switch (builtin.os.tag) {
        .linux => {
            if (builtin.cpu.arch != .x86_64) @compileError("Linux terminal ABI supports x86_64 only");
            if (@sizeOf(Termios) != 60 or @offsetOf(Termios, "cc") != 17 or @offsetOf(Termios, "ispeed") != 52 or @offsetOf(Termios, "ospeed") != 56)
                @compileError("Unexpected glibc termios ABI");
        },
        .macos => {
            if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) @compileError("Unsupported macOS terminal architecture");
            if (@sizeOf(Termios) != 72 or @alignOf(Termios) != 8 or std.c.NCCS != 20 or @offsetOf(Termios, "cc") != 32 or @offsetOf(Termios, "ispeed") != 56 or @offsetOf(Termios, "ospeed") != 64)
                @compileError("Unexpected Darwin termios ABI");
        },
        else => unreachable,
    }
}

/// Compare configuration without Darwin's kernel-owned pending-input state.
/// raw -> canonical restoration sets PENDIN even for an empty owned PTY; the
/// independent libc probe proves that difference. Never clear it on the tty.
pub fn configuredLocalFlags(value: std.c.tc_lflag_t) std.c.tc_lflag_t {
    var result = value;
    if (comptime builtin.os.tag == .macos) result.PENDIN = false;
    return result;
}

/// Read libc terminal attributes using the selected target layout.
pub extern "c" fn tcgetattr(fd: c_int, value: *Termios) c_int;

/// 按 action 指定的时机设置终端属性（如 TCSA.NOW 立即生效）。成功返回 0。
pub extern "c" fn tcsetattr(fd: c_int, action: std.c.TCSA, value: *const Termios) c_int;

/// 原地把属性改为 raw 模式（关闭回显、规范模式和信号字符等）。
pub extern "c" fn cfmakeraw(value: *Termios) void;

/// 创建伪终端主从对；name、term、size 可为 null。成功返回 0。
pub extern "c" fn openpty(master: *c_int, slave: *c_int, name: ?[*]u8, term: ?*const Termios, size: ?*const std.c.winsize) c_int;

// Canary and roundtrip prove actual libc calls stay inside the selected ABI.
