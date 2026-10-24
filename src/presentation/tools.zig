//! 前端共享的工具展示数据和 canonical FIFO。只展示，不解析执行参数或授予权限。
//! 不依赖终端宽度/ANSI/图标，也不把原始工具结果 JSON 作为展示正文。
const std = @import("std");
const p = @import("../core/protocol.zig");
const r = @import("../core/runtime.zig");
const clean = @import("../util/display_text.zig");
const tool_preview = @import("../core/tool_preview.zig");
pub const FileStats = @import("../util/line_stats.zig").File;
pub const call_limit = 256;

pub const Kind = enum {
    memory,
    bash,
    read,
    write,
    /// Child-job start; only its bounded task summary is displayable.
    subagent,
    /// get/send/cancel job control; the bounded id is the only detail.
    subagent_id,
    /// Child -> parent status; no separate panel and no message body.
    parent_message,
    other,
    pub fn fromName(name: []const u8) Kind {
        if (std.mem.eql(u8, name, "memory")) return .memory;
        if (std.mem.eql(u8, name, "bash")) return .bash;
        if (std.mem.eql(u8, name, "read_file")) return .read;
        if (std.mem.eql(u8, name, "write_file")) return .write;
        if (std.mem.eql(u8, name, "subagent")) return .subagent;
        if (std.mem.eql(u8, name, "get_subagent_result") or std.mem.eql(u8, name, "send_subagent_message") or std.mem.eql(u8, name, "cancel_subagent")) return .subagent_id;
        if (std.mem.eql(u8, name, "message_parent")) return .parent_message;
        return .other;
    }
};
pub const Outcome = enum { pending, success, failed, canceled };

/// 字段可直接用于 Web view/DTO。detail 是有界安全文本(非HTML)，没有终端cell裁剪；
/// unavailable(null)与实际空command/path不同。truncated不能冒充完整参数。
pub const Call = struct {
    kind: Kind,
    detail: ?[]const u8 = null,
    truncated: bool = false,

    pub fn init(a: std.mem.Allocator, name: []const u8, arguments: []const u8) !Call {
        const kind = Kind.fromName(name);
        if (kind == .other) return .{ .kind = kind };
        if (arguments.len > 64 * 1024) return .{ .kind = kind };
        const parsed = std.json.parseFromSlice(std.json.Value, a, arguments, .{ .allocate = .alloc_if_needed, .max_value_len = 64 * 1024 }) catch |err| {
            if (err == error.OutOfMemory) return err;
            return .{ .kind = kind };
        };
        defer parsed.deinit();
        if (parsed.value != .object) return .{ .kind = kind };
        if (kind == .memory) {
            const action_value = parsed.value.object.get("action") orelse return .{ .kind = kind };
            if (action_value != .string) return .{ .kind = kind };
            const action = action_value.string;
            if (!std.mem.eql(u8, action, "list") and !std.mem.eql(u8, action, "read") and !std.mem.eql(u8, action, "write") and !std.mem.eql(u8, action, "delete")) return .{ .kind = kind };
            const topic = parsed.value.object.get("topic");
            const target = if (std.mem.eql(u8, action, "list")) "core/index" else if (topic != null and topic.? == .string) topic.?.string else "(topic unavailable)";
            // Only known action and target metadata, never content or versions.
            // This description is not argument validation or permission policy.
            const raw = try std.fmt.allocPrint(a, "{s} {s}", .{ action, target });
            defer a.free(raw);
            return fromDetail(a, kind, raw);
        }
        // A child status row only needs the tool name; never its message body.
        if (kind == .parent_message) return .{ .kind = kind };
        const value = parsed.value.object.get(switch (kind) {
            .bash => "command",
            // Only the delegation goal is a caption; context and every other
            // argument stay out of the row entirely.
            .subagent => "task",
            // Job control exposes only the opaque bounded id.
            .subagent_id => "id",
            else => "path",
        }) orelse return .{ .kind = kind };
        if (value != .string) return .{ .kind = kind };
        return fromDetail(a, kind, value.string);
    }

    /// Typed, display-only fields, extracted before a Bridge can clip raw JSON.
    /// Missing fields remain unknown; no string repair or execution validation.
    pub fn fromFields(a: std.mem.Allocator, name: []const u8, fields: tool_preview.Snapshot) !Call {
        const kind = Kind.fromName(name);
        if (kind == .other) return .{ .kind = kind };
        // A delegation row shows only the bounded task summary. `context` is
        // deliberately not extracted, so it can never reach a caption.
        if (kind == .subagent) return fromField(a, kind, fields.task);
        if (kind == .subagent_id) return fromField(a, kind, fields.id);
        if (kind == .parent_message) return .{ .kind = kind };
        if (kind == .memory) {
            const action = fields.action orelse return .{ .kind = kind };
            if (action.truncated) return .{ .kind = kind };
            if (!std.mem.eql(u8, action.text, "list") and !std.mem.eql(u8, action.text, "read") and !std.mem.eql(u8, action.text, "write") and !std.mem.eql(u8, action.text, "delete")) return .{ .kind = kind };
            const target: ?tool_preview.Field = if (std.mem.eql(u8, action.text, "list")) .{ .text = "core/index" } else fields.topic;
            const raw = if (target) |value| try std.fmt.allocPrint(a, "{s} {s}", .{ action.text, value.text }) else try a.dupe(u8, action.text);
            defer a.free(raw);
            var call = try fromDetail(a, kind, raw);
            call.truncated = call.truncated or (if (target) |value| value.truncated else false);
            return call;
        }
        const field = (if (kind == .bash) fields.command else fields.path) orelse return .{ .kind = kind };
        return fromField(a, kind, field);
    }

    fn fromField(a: std.mem.Allocator, kind: Kind, field: ?tool_preview.Field) !Call {
        const value = field orelse return .{ .kind = kind };
        var call = try fromDetail(a, kind, value.text);
        call.truncated = call.truncated or value.truncated;
        return call;
    }

    fn fromDetail(a: std.mem.Allocator, kind: Kind, bytes: []const u8) !Call {
        const prefix = try clean.sanitizePrefix(a, bytes, 512);
        for (prefix.text) |*byte| if (byte.* == '\n' or byte.* == '\t') {
            byte.* = ' ';
        };
        return .{ .kind = kind, .detail = prefix.text, .truncated = prefix.truncated };
    }

    pub fn deinit(self: Call, a: std.mem.Allocator) void {
        if (self.detail) |detail| a.free(detail);
    }
};

/// 数字原样保留 unknown/partial；失败/取消不能借数字声称操作已经完成。
pub const Completion = struct {
    outcome: Outcome,
    file_stats: ?FileStats,
    duration_ms: ?u64 = null,

    pub fn fromExecution(result: r.Execution) Completion {
        const outcome: Outcome = if (result.canceled) .canceled else if (result.is_error) .failed else .success;
        return .{ .outcome = outcome, .file_stats = if (outcome == .success) result.file_stats else null, .duration_ms = result.duration_ms };
    }
};

/// Read failures are known local error identifiers, never arbitrary tool output
/// or JSON. Exact matching keeps hostile/control/secret-bearing bodies out of
/// captions; all returned strings are static and frontend-neutral.
pub fn readFailure(result: r.Execution) ?[]const u8 {
    if (!result.is_error or result.canceled) return null;
    const reasons = .{
        .{ "FileNotFound", "FileNotFound: file not found" },
        .{ "AccessDenied", "AccessDenied: permission denied" },
        .{ "OutsideRoot", "OutsideRoot: outside project root" },
        .{ "PathEscape", "PathEscape: outside project root" },
        .{ "InvalidPath", "InvalidPath: invalid file path" },
        .{ "IsDir", "IsDir: path is a directory" },
        .{ "NotDir", "NotDir: parent is not a directory" },
        .{ "NotRegularFile", "NotRegularFile: not a regular file" },
        .{ "SymlinkNotAllowed", "SymlinkNotAllowed: symlink refused" },
        .{ "BinaryFile", "BinaryFile: binary file is not readable as text" },
        .{ "InvalidUtf8", "InvalidUtf8: file is not valid UTF-8" },
        .{ "InvalidOffset", "InvalidOffset: invalid byte offset" },
        .{ "InvalidLimit", "InvalidLimit: invalid read limit" },
        .{ "InvalidReadLimit", "InvalidReadLimit: invalid read limit" },
        .{ "ReadLimitTooSmall", "ReadLimitTooSmall: limit cannot fit a character" },
        .{ "NameTooLong", "NameTooLong: file path is too long" },
        .{ "FileChanged", "FileChanged: file changed while reading" },
        .{ "ProtectedAuthFile", "ProtectedAuthFile: protected credential file" },
        .{ "ProtectedSettingsFile", "ProtectedSettingsFile: protected settings" },
        .{ "ProtectedSessionFile", "ProtectedSessionFile: protected session data" },
        .{ "UseMemoryTool", "UseMemoryTool: use memory tool for this path" },
        .{ "UnknownField", "UnknownField: unsupported read argument" },
        .{ "MissingField", "MissingField: required read argument missing" },
        .{ "ArgumentsTooLarge", "ArgumentsTooLarge: read arguments too large" },
        .{ "FileSystemError", "FileSystemError: filesystem read failed" },
        .{ "OutOfMemory", "OutOfMemory: insufficient memory" },
    };
    inline for (reasons) |reason| {
        if (std.mem.eql(u8, result.text, reason[0])) return reason[1];
    }
    return "Read failed: details unavailable";
}

test "read failure captions expose known reasons but never raw tool bodies" {
    try std.testing.expectEqualStrings("FileNotFound: file not found", readFailure(.{ .text = "FileNotFound", .is_error = true }).?);
    try std.testing.expectEqualStrings("AccessDenied: permission denied", readFailure(.{ .text = "AccessDenied", .is_error = true }).?);
    for ([_][]const u8{ "{\"error\":\"private-body\"}", "FileNotFound\nprivate-body", "\x1b[2JFileNotFound", "unknown-private-error" }) |raw| {
        try std.testing.expectEqualStrings("Read failed: details unavailable", readFailure(.{ .text = raw, .is_error = true }).?);
    }
    try std.testing.expect(readFailure(.{ .text = "FileNotFound" }) == null);
    try std.testing.expect(readFailure(.{ .text = "FileNotFound", .is_error = true, .canceled = true }) == null);
}

/// 成员拥有各Call；take交出唯一所有权。调用方收到started/result后依次消费，
/// 包括没有started的prepare失败或deny。只使用canonical块，不采信tool_preview。
pub const Queue = struct {
    items: std.ArrayList(Call) = .empty,
    cursor: usize = 0,

    pub fn clear(self: *Queue, a: std.mem.Allocator) void {
        for (self.items.items[self.cursor..]) |call| call.deinit(a);
        self.items.clearRetainingCapacity();
        self.cursor = 0;
    }
    pub fn deinit(self: *Queue, a: std.mem.Allocator) void {
        self.clear(a);
        self.items.deinit(a);
    }
    pub fn capture(self: *Queue, a: std.mem.Allocator, blocks: []const p.Block) !void {
        self.clear(a);
        for (blocks[0..@min(blocks.len, call_limit)]) |block| if (block == .tool_call) {
            const call = try Call.init(a, block.tool_call.name, block.tool_call.arguments);
            errdefer call.deinit(a);
            try self.items.append(a, call);
        };
    }
    pub fn take(self: *Queue, name: []const u8, a: std.mem.Allocator) !Call {
        if (self.cursor < self.items.items.len) {
            const call = self.items.items[self.cursor];
            self.cursor += 1;
            if (call.kind == Kind.fromName(name)) return call;
            call.deinit(a);
        }
        return Call.init(a, name, "");
    }
};

test "typed tool fields keep unknown targets safe and preserve clipping provenance" {
    const a = std.testing.allocator;
    const missing = try Call.fromFields(a, "write_file", .{});
    defer missing.deinit(a);
    try std.testing.expect(missing.kind == .write and missing.detail == null);
    const path = try Call.fromFields(a, "read_file", .{ .path = .{ .text = "中文\x1b[2J\nfile", .truncated = true } });
    defer path.deinit(a);
    try std.testing.expect(path.truncated and path.kind == .read);
    try std.testing.expect(std.mem.findScalar(u8, path.detail.?, '\x1b') == null);
    try std.testing.expect(std.mem.findScalar(u8, path.detail.?, '\n') == null);
    const command = try Call.fromFields(a, "bash", .{ .path = .{ .text = "wrong" }, .command = .{ .text = "echo hello" } });
    defer command.deinit(a);
    try std.testing.expectEqualStrings("echo hello", command.detail.?);
    const action = try Call.fromFields(a, "memory", .{ .action = .{ .text = "write" } });
    defer action.deinit(a);
    try std.testing.expectEqualStrings("write", action.detail.?);
    const topic = try Call.fromFields(a, "memory", .{ .action = .{ .text = "read" }, .topic = .{ .text = "core" } });
    defer topic.deinit(a);
    try std.testing.expectEqualStrings("read core", topic.detail.?);
    const invalid = try Call.fromFields(a, "memory", .{ .action = .{ .text = "write", .truncated = true }, .topic = .{ .text = "hidden" } });
    defer invalid.deinit(a);
    try std.testing.expect(invalid.detail == null);
}

test "memory descriptions include known action and topic without bodies versions or styles" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "read", "write", "delete" }) |action| {
        const args = try std.fmt.allocPrint(a, "{{\"action\":\"{s}\",\"topic\":\"core\",\"content\":\"private-body\",\"expected_version\":\"private-version\"}}", .{action});
        defer a.free(args);
        const call = try Call.init(a, "memory", args);
        defer call.deinit(a);
        const expected = try std.fmt.allocPrint(a, "{s} core", .{action});
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, call.detail.?);
        try std.testing.expect(!call.truncated);
    }
    const list = try Call.init(a, "memory", "{\"action\":\"list\"}");
    defer list.deinit(a);
    try std.testing.expectEqualStrings("list core/index", list.detail.?);
    const unsafe = try Call.init(a, "memory", "{\"action\":\"write\",\"topic\":\"topic\\u001b[2J\\nend\"}");
    defer unsafe.deinit(a);
    try std.testing.expect(std.mem.findScalar(u8, unsafe.detail.?, '\x1b') == null);
    try std.testing.expect(std.mem.findScalar(u8, unsafe.detail.?, '\n') == null);
    for ([_][]const u8{ "{\"action\":\"invented\"}", "{\"action\":\"read\",\"topic\":", "[]" }) |args| {
        const unknown = try Call.init(a, "memory", args);
        defer unknown.deinit(a);
        try std.testing.expect(unknown.detail == null);
    }
    const long_topic: [600]u8 = @splat('a');
    const long_args = try std.fmt.allocPrint(a, "{{\"action\":\"read\",\"topic\":\"{s}\"}}", .{long_topic[0..]});
    defer a.free(long_args);
    const long = try Call.init(a, "memory", long_args);
    defer long.deinit(a);
    try std.testing.expect(long.truncated and long.detail.?.len <= 512);
}

test "subagent captions keep only a bounded task summary and never context" {
    const a = std.testing.allocator;
    const call = try Call.init(a, "subagent", "{\"task\":\"检查资源释放路径\",\"context\":\"private-context-body\"}");
    defer call.deinit(a);
    try std.testing.expect(call.kind == .subagent);
    try std.testing.expectEqualStrings("检查资源释放路径", call.detail.?);
    try std.testing.expect(std.mem.find(u8, call.detail.?, "private-context-body") == null);
    try std.testing.expect(!call.truncated);
    const hostile = try Call.init(a, "subagent", "{\"task\":\"a\\u001b[2J\\tb\\n\"}");
    defer hostile.deinit(a);
    try std.testing.expect(std.mem.findScalar(u8, hostile.detail.?, '\x1b') == null);
    try std.testing.expect(std.mem.findScalar(u8, hostile.detail.?, '\n') == null);
    try std.testing.expect(std.mem.findScalar(u8, hostile.detail.?, '\t') == null);
    var args: std.Io.Writer.Allocating = .init(a);
    defer args.deinit();
    try args.writer.writeAll("{\"task\":\"");
    for (0..2048) |_| try args.writer.writeAll("中");
    try args.writer.writeAll("\",\"context\":\"hidden-body\"}");
    const long = try Call.init(a, "subagent", args.written());
    defer long.deinit(a);
    try std.testing.expect(long.truncated and long.detail.?.len <= 512);
    try std.testing.expect(std.unicode.utf8ValidateSlice(long.detail.?));
    try std.testing.expect(std.mem.find(u8, long.detail.?, "hidden-body") == null);
    for ([_][]const u8{ "{}", "{\"context\":\"only\"}", "{\"task\":42}", "{\"task\":null}", "{\"task\":missing", "[]", "" }) |raw| {
        const unknown = try Call.init(a, "subagent", raw);
        defer unknown.deinit(a);
        try std.testing.expect(unknown.kind == .subagent and unknown.detail == null);
    }
    // The typed streaming field is the same bounded summary; unrelated or
    // context-like fields never become a task caption.
    const streamed = try Call.fromFields(a, "subagent", .{ .task = .{ .text = "inspect release paths", .truncated = true }, .path = .{ .text = "wrong" } });
    defer streamed.deinit(a);
    try std.testing.expect(streamed.kind == .subagent and streamed.truncated);
    try std.testing.expectEqualStrings("inspect release paths", streamed.detail.?);
    const missing = try Call.fromFields(a, "subagent", .{ .path = .{ .text = "wrong" }, .command = .{ .text = "wrong" } });
    defer missing.deinit(a);
    try std.testing.expect(missing.kind == .subagent and missing.detail == null);
}

test "job control captions keep only ids and child status stays a bare tool name" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "get_subagent_result", "send_subagent_message", "cancel_subagent" }) |name| {
        const args = try std.fmt.allocPrint(a, "{{\"id\":\"job-7\",\"message\":\"private-body\",\"wait\":false}}", .{});
        defer a.free(args);
        const call = try Call.init(a, name, args);
        defer call.deinit(a);
        try std.testing.expect(call.kind == .subagent_id);
        try std.testing.expectEqualStrings("job-7", call.detail.?);
        try std.testing.expect(std.mem.find(u8, call.detail.?, "private-body") == null);
    }
    const child = try Call.init(a, "message_parent", "{\"message\":\"private-body\",\"wait_for_reply\":true}");
    defer child.deinit(a);
    try std.testing.expect(child.kind == .parent_message and child.detail == null);
    const streamed = try Call.fromFields(a, "cancel_subagent", .{ .id = .{ .text = "job-9", .truncated = true }, .task = .{ .text = "wrong" } });
    defer streamed.deinit(a);
    try std.testing.expect(streamed.kind == .subagent_id and streamed.truncated);
    try std.testing.expectEqualStrings("job-9", streamed.detail.?);
    const unknown = try Call.fromFields(a, "get_subagent_result", .{ .task = .{ .text = "wrong" } });
    defer unknown.deinit(a);
    try std.testing.expect(unknown.kind == .subagent_id and unknown.detail == null);
}

test "shared tools expose structured safe detail observations and bounded FIFO without styles" {
    const a = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(a);
    try queue.capture(a, &.{
        .{ .tool_call = .{ .id = "one", .name = "bash", .arguments = "{\"command\":\"date\\n<hello>\\u001b[2J\"}" } },
        .{ .tool_call = .{ .id = "two", .name = "write_file", .arguments = "{\"path\":\"src/main.zig\",\"content\":\"not-display-content\"}" } },
    });
    const one = try queue.take("bash", a);
    defer one.deinit(a);
    try std.testing.expect(std.mem.startsWith(u8, one.detail.?, "date <hello>"));
    try std.testing.expect(std.mem.findScalar(u8, one.detail.?, '\x1b') == null);
    const two = try queue.take("write_file", a);
    defer two.deinit(a);
    try std.testing.expectEqualStrings("src/main.zig", two.detail.?);
    const complete = Completion.fromExecution(.{ .text = "hidden JSON", .file_stats = .{ .changes = .{ .modified = 3, .added = 5, .removed = 2 } } });
    try std.testing.expectEqual(@as(u64, 3), complete.file_stats.?.changes.?.modified);
    try std.testing.expect(Completion.fromExecution(.{ .text = "failed", .is_error = true, .file_stats = complete.file_stats }).file_stats == null);
    const unknown = try Call.init(a, "read_file", "{\"path\":\"partial");
    defer unknown.deinit(a);
    try std.testing.expect(unknown.detail == null);
    try std.testing.expectEqual(Kind.other, Kind.fromName("untrusted\x1b[2J"));
}
