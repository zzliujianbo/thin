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

/// Clone without recursing through arbitrary native JSON. Successful trees
/// remain caller-owned (normally by an arena); failures release every allocation.
pub fn clone(a: std.mem.Allocator, value: Value) !Value {
    const Task = struct { source: Value, destination: *Value };
    const Allocation = union(enum) {
        text: []u8,
        array: std.json.Array,
        object: std.json.ObjectMap,

        fn release(self: *@This(), allocator: std.mem.Allocator) void {
            switch (self.*) {
                .text => |bytes| allocator.free(bytes),
                .array => |*items| items.deinit(),
                .object => |*fields| fields.deinit(allocator),
            }
        }

        fn copyText(allocator: std.mem.Allocator, owned: *std.ArrayList(@This()), text: []const u8) ![]u8 {
            const bytes = try allocator.dupe(u8, text);
            errdefer allocator.free(bytes);
            try owned.append(allocator, .{ .text = bytes });
            return bytes;
        }
    };
    var tasks: std.ArrayList(Task) = .empty;
    defer tasks.deinit(a);
    var allocations: std.ArrayList(Allocation) = .empty;
    defer allocations.deinit(a);
    errdefer for (allocations.items) |*allocation| allocation.release(a);
    var result: Value = .null;
    try tasks.append(a, .{ .source = value, .destination = &result });
    while (tasks.pop()) |task| {
        switch (task.source) {
            .string => |text| task.destination.* = .{ .string = try Allocation.copyText(a, &allocations, text) },
            .number_string => |text| task.destination.* = .{ .number_string = try Allocation.copyText(a, &allocations, text) },
            .array => |source| {
                var items = std.json.Array.init(a);
                try items.ensureTotalCapacity(source.items.len);
                allocations.append(a, .{ .array = items }) catch |err| {
                    items.deinit();
                    return err;
                };
                // Fill before publishing child pointers; no later resize can
                // invalidate a queued destination.
                for (source.items) |_| items.appendAssumeCapacity(.null);
                task.destination.* = .{ .array = items };
                for (source.items, items.items) |child, *destination|
                    try tasks.append(a, .{ .source = child, .destination = destination });
            },
            .object => |source| {
                var fields: std.json.ObjectMap = .empty;
                try fields.ensureTotalCapacity(a, source.count());
                allocations.append(a, .{ .object = fields }) catch |err| {
                    fields.deinit(a);
                    return err;
                };
                for (source.keys()) |key|
                    fields.putAssumeCapacityNoClobber(try Allocation.copyText(a, &allocations, key), .null);
                task.destination.* = .{ .object = fields };
                for (source.values(), fields.values()) |child, *destination|
                    try tasks.append(a, .{ .source = child, .destination = destination });
            },
            else => task.destination.* = task.source,
        }
    }
    return result;
}

/// Encode arbitrary Value containers with an allocator-owned traversal stack.
/// Scalar formatting/escaping matches std.json; number_string stays byte-exact.
pub fn encode(a: std.mem.Allocator, value: Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    encodeInto(a, value, &out.writer) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
    return out.toOwnedSlice();
}

fn encodeInto(a: std.mem.Allocator, value: Value, writer: *std.Io.Writer) !void {
    const Frame = struct { value: Value, index: usize = 0, started: bool = false };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(a);
    try stack.append(a, .{ .value = value });
    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        switch (frame.value) {
            .array => |items| {
                if (!frame.started) {
                    try writer.writeByte('[');
                    frame.started = true;
                }
                if (frame.index == items.items.len) {
                    try writer.writeByte(']');
                    _ = stack.pop();
                    continue;
                }
                if (frame.index != 0) try writer.writeByte(',');
                const child = items.items[frame.index];
                frame.index += 1;
                try stack.append(a, .{ .value = child });
            },
            .object => |fields| {
                if (!frame.started) {
                    try writer.writeByte('{');
                    frame.started = true;
                }
                if (frame.index == fields.count()) {
                    try writer.writeByte('}');
                    _ = stack.pop();
                    continue;
                }
                if (frame.index != 0) try writer.writeByte(',');
                try std.json.Stringify.value(fields.keys()[frame.index], .{}, writer);
                try writer.writeByte(':');
                const child = fields.values()[frame.index];
                frame.index += 1;
                try stack.append(a, .{ .value = child });
            },
            .number_string => |text| {
                try writer.writeAll(text);
                _ = stack.pop();
            },
            .null => {
                try writer.writeAll("null");
                _ = stack.pop();
            },
            inline else => |scalar| {
                try std.json.Stringify.value(scalar, .{}, writer);
                _ = stack.pop();
            },
        }
    }
}
