//! Linux x86_64 *libc* terminal ABI. Do not substitute std.c.termios here:
//! Zig 0.17 aliases the kernel layout (NCCS=19, 44 bytes), but glibc's
//! tcgetattr writes the 60-byte public struct with NCCS=32. This struct is NOT
//! the layout for direct kernel TCGETS/TCSETS ioctls.
//! 中文：本文件声明 glibc 的 struct termios 布局，供 tcgetattr/tcsetattr/cfmakeraw/openpty 调用。
//! 偏移：iflag/oflag/cflag/lflag 各 4 字节（0/4/8/12），line 在 16，cc 从 17 开始占 32 字节，ispeed 在 52，ospeed 在 56，总长 60。

const std = @import("std");
const builtin = @import("builtin");

/// 与 glibc 公开的 struct termios 布局一致（60 字节，NCCS=32）。extern 保证 C 布局，字段顺序和类型不可随意调整。
pub const Termios = extern struct {
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
    // 本 ABI 仅针对 Linux x86_64 定义。
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) @compileError("Terminal ABI is Linux x86_64 only");

    // 校验总大小 60 字节以及 cc/ispeed/ospeed 的偏移，与 glibc 布局一致。
    if (@sizeOf(Termios) != 60 or @offsetOf(Termios, "cc") != 17 or @offsetOf(Termios, "ispeed") != 52 or @offsetOf(Termios, "ospeed") != 56)
        @compileError("Unexpected libc termios ABI");
}

/// 读取 fd 的终端属性到 value（glibc 布局）。成功返回 0，失败返回 -1 并设置 errno。
pub extern "c" fn tcgetattr(fd: c_int, value: *Termios) c_int;

/// 按 action 指定的时机设置终端属性（如 TCSA.NOW 立即生效）。成功返回 0。
pub extern "c" fn tcsetattr(fd: c_int, action: std.c.TCSA, value: *const Termios) c_int;

/// 原地把属性改为 raw 模式（关闭回显、规范模式和信号字符等）。
pub extern "c" fn cfmakeraw(value: *Termios) void;

/// 创建伪终端主从对；name、term、size 可为 null。成功返回 0。
pub extern "c" fn openpty(master: *c_int, slave: *c_int, name: ?[*]u8, term: ?*const Termios, size: ?*const std.c.winsize) c_int;

// 测试：确认 libc 只写入 Termios 的 60 字节，并通过 canary 检测越界写入。
test "libc terminal attributes stay inside explicit ABI canaries" {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), openpty(&master, &slave, null, null, null));
    defer _ = std.c.close(master);
    defer _ = std.c.close(slave);

    // canary 紧跟在 Termios 之后：若 libc 写入超出 60 字节，canary 会被改写并使测试失败。
    const Guarded = extern struct { value: Termios, canary: [32]u8 };
    var guarded: Guarded = .{ .value = undefined, .canary = @splat(0xa7) };

    try std.testing.expectEqual(@as(c_int, 0), tcgetattr(slave, &guarded.value));
    const marker: [32]u8 = @splat(0xa7);
    try std.testing.expectEqualSlices(u8, &marker, &guarded.canary);

    // 保存原始属性，用于测试结束前恢复终端状态，并逐字段比较 round trip 结果。
    const original = guarded.value;
    cfmakeraw(&guarded.value);
    try std.testing.expectEqualSlices(u8, &marker, &guarded.canary);
    try std.testing.expectEqual(@as(c_int, 0), tcsetattr(slave, .NOW, &guarded.value));
    try std.testing.expectEqual(@as(c_int, 0), tcsetattr(slave, .NOW, &original));
    try std.testing.expectEqual(@as(c_int, 0), tcgetattr(slave, &guarded.value));
    try std.testing.expectEqualSlices(u8, &marker, &guarded.canary);

    try std.testing.expectEqual(original.iflag, guarded.value.iflag);
    try std.testing.expectEqual(original.oflag, guarded.value.oflag);
    try std.testing.expectEqual(original.cflag, guarded.value.cflag);
    try std.testing.expectEqual(original.lflag, guarded.value.lflag);
    try std.testing.expectEqualSlices(u8, &original.cc, &guarded.value.cc);
    try std.testing.expectEqual(original.ispeed, guarded.value.ispeed);
    try std.testing.expectEqual(original.ospeed, guarded.value.ospeed);
}
