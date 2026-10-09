//! JSON 辅助函数：基于 std.json 的节点构建、字段读取、解析与序列化。
//! 约定：树节点与字符串由调用方传入的 allocator（通常是 arena）持有，本模块不接管所有权。

const std = @import("std");

/// 标准库 JSON 值类型的别名，全项目统一使用。
pub const Value = std.json.Value;

/// Helpers for arena-owned JSON trees. They do not take ownership of strings.
/// 创建空 object 节点；参数未使用，仅保持与其他构造函数签名一致。
pub fn object(_: std.mem.Allocator) Value {
    return .{ .object = .{} };
}

/// 创建空 array 节点，元素列表使用传入的 allocator 分配。
pub fn array(a: std.mem.Allocator) Value {
    return .{ .array = std.array_list.Managed(Value).init(a) };
}

/// 向 object 节点写入字段，内部 map 使用 a 分配内存。
pub fn put(a: std.mem.Allocator, v: *Value, key: []const u8, value: Value) !void {
    try v.object.put(a, key, value);
}

/// 向 array 节点末尾追加元素。
pub fn append(v: *Value, value: Value) !void {
    try v.array.append(value);
}

/// 包装字符串为 JSON 值，不复制内容：返回值直接引用 s，s 必须比树活得更久。
pub fn str(s: []const u8) Value {
    return .{ .string = s };
}

/// 将 u64 转为 JSON 整数。std.json 整数使用 i64，超出范围时返回 error.InvalidNumber。
pub fn number(n: u64) !Value {
    if (n > std.math.maxInt(i64)) return error.InvalidNumber;
    return .{ .integer = @intCast(n) };
}

/// 仅当 v 是 object 且包含 key 时返回字段值，否则返回 null（不报错，便于可选读取）。
pub fn get(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}

/// 取出字符串内容；字段缺失或类型不符时返回 null。
pub fn string(v: ?Value) ?[]const u8 {
    const item = v orelse return null;
    return if (item == .string) item.string else null;
}

/// 取出非负整数并转为 u64；负数、非整数或缺失时返回 null。
pub fn uint(v: ?Value) ?u64 {
    const item = v orelse return null;
    return if (item == .integer and item.integer >= 0) @intCast(item.integer) else null;
}

/// 解析 JSON 字节为 Value。使用 parseFromSliceLeaky，结果不单独释放，全部由 a 管理（适合 arena）。
/// alloc_always 保证字符串总是被复制，结果不引用输入 bytes，因此输入可以提前释放。
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always });
}

/// 将 Value 序列化为新分配的 JSON 字符串，内存由 a 分配，调用方需用同一 allocator 释放。
pub fn encode(a: std.mem.Allocator, value: Value) ![]u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}
