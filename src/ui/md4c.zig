//! MD4C 0.5.2's UTF-8 C ABI, declared explicitly (Zig 0.17 has no @cImport).
//! Upstream headers and MIT license are vendored under src/vendor/md4c.
const std = @import("std");
pub const Attribute = extern struct { text: ?[*]const u8, size: c_uint, types: ?[*]const c_int, offsets: ?[*]const c_uint };
pub const Ul = extern struct { tight: c_int, mark: u8 };
pub const Ol = extern struct { start: c_uint, tight: c_int, delimiter: u8 };
pub const Li = extern struct { task: c_int, mark: u8, offset: c_uint };
pub const H = extern struct { level: c_uint };
pub const Code = extern struct { info: Attribute, lang: Attribute, fence: u8 };
pub const Table = extern struct { columns: c_uint, head_rows: c_uint, body_rows: c_uint };
pub const Td = extern struct { alignment: c_int };
pub const Link = extern struct { href: Attribute, title: Attribute, autolink: c_int };
pub const Image = extern struct { src: Attribute, title: Attribute };
pub const Parser = extern struct {
    version: c_uint = 0,
    flags: c_uint = 0x0004 | 0x0008 | 0x0020 | 0x0040 | 0x0100 | 0x0200 | 0x0400 | 0x0800 | 0x1000,
    enter_block: *const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) c_int,
    leave_block: *const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) c_int,
    enter_span: *const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) c_int,
    leave_span: *const fn (c_int, ?*anyopaque, ?*anyopaque) callconv(.c) c_int,
    text: *const fn (c_int, [*]const u8, c_uint, ?*anyopaque) callconv(.c) c_int,
    debug: ?*const fn ([*:0]const u8, ?*anyopaque) callconv(.c) void = null,
    syntax: ?*const fn () callconv(.c) void = null,
};
pub const Entity = extern struct { name: [*:0]const u8, codepoints: [2]c_uint };
pub extern "c" fn md_parse([*]const u8, c_uint, *const Parser, ?*anyopaque) c_int;
pub extern "c" fn entity_lookup([*]const u8, usize) ?*const Entity;
extern "c" fn thin_md4c_abi() c_int;
extern "c" fn thin_md4c_fault_test() c_int;

test "vendored parser preserves ownership at every allocation failure" {
    try std.testing.expectEqual(@as(c_int, 0), thin_md4c_fault_test());
}

test "vendored Markdown C ABI matches explicit Zig declarations" {
    try std.testing.expectEqual(@as(c_int, 1), thin_md4c_abi());
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Parser));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Attribute));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Code));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Link));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Li));
}
