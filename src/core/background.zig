//! 实例内后台命令的纯契约层：DTO、参数校验与服务回调。
//!
//! 本模块不导入 App / TTY / 平台进程，也不持有任何状态。
//! 由 `app/background_service.zig` 实现 `Service`，由 Tools 构造 `Start` 并消费 `Result`。
const std = @import("std");
const protocol = @import("protocol.zig");

pub const Cancellation = protocol.Cancellation;

/// 工具层 `{"action":"list"}` 的默认页大小（不是服务数量上限）。
pub const default_page_limit: u32 = 20;
/// 单页最多返回多少条记录（不是服务数量上限）。
pub const max_page_limit: u32 = 100;
/// `logs` 默认的 stdout+stderr 原始字节总读取预算。
pub const default_log_budget: u32 = 4096;
/// `logs` 单次允许的最大原始字节总读取预算。
pub const max_log_budget: u32 = 16384;
/// ID 最大长度（随机实例前缀 + 单调序号）。
pub const max_id_len: usize = 64;

pub const Action = enum {
    list,
    status,
    logs,
    stop,

    pub fn name(self: Action) []const u8 {
        return switch (self) {
            .list => "list",
            .status => "status",
            .logs => "logs",
            .stop => "stop",
        };
    }
};

/// 由 Tools 依据已接受的参数与配置构造；不直接来自工具 JSON。
/// 只描述启动窗口与清理预算，不包含命令运行期 deadline（后台命令无 deadline）。
pub const Start = struct {
    command: []const u8,
    /// 有界启动等待（config 的 u32 毫秒，0 视为无效）。
    startup_timeout_ms: u32,
    /// stdout+stderr 日志环总容量（原始字节），两路各半。
    log_bytes: u32,
    term_grace_ms: u32,
    cleanup_timeout_ms: u32,
};

pub const Query = struct {
    action: Action,
    id: ?[]const u8 = null,
    after: ?u64 = null,
    stdout_offset: ?u64 = null,
    stderr_offset: ?u64 = null,
    limit: ?u32 = null,
};

/// 已编码的响应；Tools 不再重复编码。
pub const Result = struct {
    text: []const u8,
    is_error: bool = false,
    cleanup_failed: bool = false,
    canceled: bool = false,
    truncated: bool = false,

    pub fn ok(text: []const u8) Result {
        return .{ .text = text };
    }

    pub fn failed(text: []const u8) Result {
        return .{ .text = text, .is_error = true };
    }
};

pub const ValidationError = error{InvalidQuery};

/// 按 action 严格校验：拒绝无关字段、非法游标、超限读取与非法 ID。
pub fn validateQuery(q: Query) ValidationError!void {
    switch (q.action) {
        .list => {
            if (q.id != null) return error.InvalidQuery;
            if (q.stdout_offset != null or q.stderr_offset != null) return error.InvalidQuery;
            if (q.limit) |limit| {
                if (limit == 0 or limit > max_page_limit) return error.InvalidQuery;
            }
        },
        .status, .stop => {
            if (q.id == null) return error.InvalidQuery;
            if (q.after != null or q.stdout_offset != null or q.stderr_offset != null) return error.InvalidQuery;
            if (q.limit != null) return error.InvalidQuery;
        },
        .logs => {
            if (q.id == null) return error.InvalidQuery;
            if (q.after != null) return error.InvalidQuery;
            if (q.limit) |limit| {
                if (limit == 0 or limit > max_log_budget) return error.InvalidQuery;
            }
        },
    }
    if (q.id) |id| {
        if (!validId(id)) return error.InvalidQuery;
    }
}

/// 严格管理参数解析的错误面：任何无效 JSON/类型/字段/数字问题都是 `InvalidQuery`，
/// 只有分配失败原样传播为 `OutOfMemory`。
pub const ParseError = error{ InvalidQuery, OutOfMemory };

/// 从原始管理 JSON 构造 `Query`：只按 `action` 允许的字段存在性名单接受字段，
/// 不依赖 `std.json` 转 DTO 时的隐式宽松行为（整数的带引号字符串、enum 的数值 tag、
/// 以及把 `null` 当成缺省而隐去无关字段）。
///
/// 返回值的 `id` 由调用方 allocator `a` 拥有，其余字段都是标量。
pub fn parseQuery(a: std.mem.Allocator, bytes: []const u8) ParseError!Query {
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .allocate = .alloc_always,
        // 数值保留精确原文，避免经过 f64 丢失 u64 精度。
        .parse_numbers = false,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidQuery,
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidQuery,
    };
    // `action` 必须是字符串，且必须是已知枚举名；枚举数值 tag 一律拒绝。
    const action_text = switch (object.get("action") orelse return error.InvalidQuery) {
        .string => |value| value,
        else => return error.InvalidQuery,
    };
    const action = std.meta.stringToEnum(Action, action_text) orelse return error.InvalidQuery;

    // 按 action 的字段存在性名单遍历：不需要的字段即使值为 null 也必须拒绝。
    const allowed: []const []const u8 = switch (action) {
        .list => &.{ "action", "after", "limit" },
        .status, .stop => &.{ "action", "id" },
        .logs => &.{ "action", "id", "stdout_offset", "stderr_offset", "limit" },
    };
    var fields = object.iterator();
    while (fields.next()) |entry| {
        var known = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidQuery;
    }

    var q = Query{ .action = action };
    if (object.get("after")) |value| q.after = try parseUnsigned(value);
    if (object.get("stdout_offset")) |value| q.stdout_offset = try parseUnsigned(value);
    if (object.get("stderr_offset")) |value| q.stderr_offset = try parseUnsigned(value);
    if (object.get("limit")) |value| {
        q.limit = std.math.cast(u32, try parseUnsigned(value)) orelse return error.InvalidQuery;
    }
    // 先沿用借用 parsed 字符串的 id 做完整校验，成功后只复制 id。
    if (object.get("id")) |value| {
        q.id = switch (value) {
            .string => |text| text,
            else => return error.InvalidQuery,
        };
    }
    try validateQuery(q);
    if (q.id) |id| q.id = try a.dupe(u8, id);
    return q;
}

/// 只接受未加引号的 JSON 数字原文：ASCII 十进制无符号整数（无符号位/小数点/指数/引号）。
fn parseUnsigned(value: std.json.Value) ParseError!u64 {
    const text = switch (value) {
        .number_string => |raw| raw,
        else => return error.InvalidQuery,
    };
    if (text.len == 0) return error.InvalidQuery;
    for (text) |ch| {
        if (ch < '0' or ch > '9') return error.InvalidQuery;
    }
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidQuery;
}

/// ID 形如 `<随机实例前缀>-<单调序号>`，仅小写十六进制/数字与 `-`。
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    var separator: usize = 0;
    for (id, 0..) |ch, index| {
        if (ch == '-') {
            if (index == 0 or index + 1 == id.len) return false;
            if (separator != 0) return false;
            separator = index;
            continue;
        }
        const digit = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
        if (!digit) return false;
    }
    return separator != 0;
}

/// 分页游标：`after` 之后最多 `limit` 条（默认 `default_page_limit`）。
pub fn pageLimit(q: Query) u32 {
    return q.limit orelse default_page_limit;
}

/// 日志原始字节总预算（默认 `default_log_budget`）。
pub fn logBudget(q: Query) u32 {
    return q.limit orelse default_log_budget;
}

/// 服务回调集合。`context` 由实现方决定，生命周期与实现方一致。
pub const Service = struct {
    context: *anyopaque,
    start_fn: *const fn (context: *anyopaque, a: std.mem.Allocator, start: Start, cancel: *const Cancellation) anyerror!Result,
    control_fn: *const fn (context: *anyopaque, a: std.mem.Allocator, query: Query, cancel: *const Cancellation) anyerror!Result,
    check_fn: *const fn (context: *anyopaque) anyerror!void,

    pub fn start(self: Service, a: std.mem.Allocator, start_args: Start, cancel: *const Cancellation) anyerror!Result {
        return self.start_fn(self.context, a, start_args, cancel);
    }

    pub fn control(self: Service, a: std.mem.Allocator, query: Query, cancel: *const Cancellation) anyerror!Result {
        return self.control_fn(self.context, a, query, cancel);
    }

    /// 已交接服务的健康检查：异步清理失败必须让本轮失败，不停止已交接服务。
    pub fn checkReady(self: Service) anyerror!void {
        return self.check_fn(self.context);
    }
};

const testing = std.testing;

test "validateQuery rejects cross-action fields" {
    try validateQuery(.{ .action = .list });
    try validateQuery(.{ .action = .list, .after = 3, .limit = 100 });
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .list, .id = "ab-1" }));
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .list, .limit = 101 }));
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .list, .limit = 0 }));
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .list, .stdout_offset = 0 }));

    try validateQuery(.{ .action = .status, .id = "ab-1" });
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .status }));
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .status, .id = "ab-1", .after = 0 }));
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .status, .id = "ab-1", .limit = 20 }));

    try validateQuery(.{ .action = .logs, .id = "ab-1", .stdout_offset = 0, .stderr_offset = 9, .limit = 16384 });
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .logs, .id = "ab-1", .limit = 16385 }));
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .logs, .id = "ab-1", .after = 1 }));

    try validateQuery(.{ .action = .stop, .id = "ab-1" });
    try testing.expectError(error.InvalidQuery, validateQuery(.{ .action = .stop }));
}

test "validId bounds and charset" {
    try testing.expect(validId("0123456789ab-1"));
    try testing.expect(!validId(""));
    try testing.expect(!validId("-1"));
    try testing.expect(!validId("ab-"));
    try testing.expect(!validId("AB-1"));
    try testing.expect(!validId("ab-1-2"));
    try testing.expect(!validId("ab 1"));
    var long_id: [70]u8 = @splat('a');
    long_id[69] = '1';
    try testing.expect(!validId(&long_id));
    var long_sep: [70]u8 = @splat('a');
    long_sep[34] = '-';
    try testing.expect(!validId(&long_sep));
}

test "defaults" {
    try testing.expectEqual(@as(u32, 20), pageLimit(.{ .action = .list }));
    try testing.expectEqual(@as(u32, 100), pageLimit(.{ .action = .list, .limit = 100 }));
    try testing.expectEqual(@as(u32, 4096), logBudget(.{ .action = .logs }));
    try testing.expectEqual(@as(u32, 16384), logBudget(.{ .action = .logs, .limit = 16384 }));
}

test "parseQuery rejects coercion, null fields and duplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // action 必须是字符串枚举名，数值 tag 与数字字符串都不接受。
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":1}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"1\"}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"restart\"}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "[]"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "null"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{"));

    // 数值只接受未加引号的整数原文。
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":\"1\"}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":1.0}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":1e0}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":1.5}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":-1}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"after\":-0}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"after\":18446744073709551616}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"logs\",\"id\":\"0123456789ab-1\",\"stdout_offset\":1.0}"));
    // limit 上限仍由 validateQuery 决定。
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":101}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":0}"));

    // null 不等于缺省：无关字段、必填字段、未知字段都拒绝。
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"limit\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"id\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"status\",\"id\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"status\",\"limit\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"logs\",\"id\":\"0123456789ab-1\",\"after\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"stop\",\"id\":\"0123456789ab-1\",\"stderr_offset\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"unknown\":null}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"status\",\"id\":\"0123456789ab-1\",\"unknown\":null}"));

    // id 只能是字符串，且仍要满足 validId。
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"status\",\"id\":1}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"stop\",\"id\":\"ABCDEF012345-1\"}"));

    // 重复字段必须报错，不得静默采用其中一个。
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"action\":\"list\"}"));
    try testing.expectError(error.InvalidQuery, parseQuery(a, "{\"action\":\"list\",\"after\":1,\"after\":2}"));
}

test "parseQuery accepts strict per-action fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const list = try parseQuery(a, "{\"action\":\"list\"}");
    try testing.expectEqual(Action.list, list.action);
    try testing.expect(list.id == null and list.after == null and list.limit == null);

    const paged = try parseQuery(a, "{\"action\":\"list\",\"after\":3,\"limit\":100}");
    try testing.expectEqual(@as(?u64, 3), paged.after);
    try testing.expectEqual(@as(?u32, 100), paged.limit);

    const status = try parseQuery(a, "{\"action\":\"status\",\"id\":\"0123456789ab-1\"}");
    try testing.expectEqual(Action.status, status.action);
    try testing.expectEqualStrings("0123456789ab-1", status.id.?);
    try testing.expect(status.after == null and status.limit == null);

    const logs = try parseQuery(a, "{\"action\":\"logs\",\"id\":\"0123456789ab-1\",\"stdout_offset\":0,\"stderr_offset\":9,\"limit\":16384}");
    try testing.expectEqual(@as(?u64, 0), logs.stdout_offset);
    try testing.expectEqual(@as(?u64, 9), logs.stderr_offset);
    try testing.expectEqual(@as(?u32, 16384), logs.limit);

    const stop = try parseQuery(a, "{\"action\":\"stop\",\"id\":\"0123456789ab-1\"}");
    try testing.expectEqual(Action.stop, stop.action);
}

test "parseQuery keeps exact u64 cursors without f64" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const paged = try parseQuery(a, "{\"action\":\"list\",\"after\":18446744073709551615}");
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), paged.after);

    const far = try parseQuery(a, "{\"action\":\"logs\",\"id\":\"0123456789ab-1\",\"stdout_offset\":18446744073709551615,\"stderr_offset\":18446744073709551614}");
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), far.stdout_offset);
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64) - 1), far.stderr_offset);
}
