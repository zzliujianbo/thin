//! 前端共享的工具展示数据和 canonical FIFO。只展示，不解析执行参数或授予权限。
//! 不依赖终端宽度/ANSI/图标，也不把原始工具结果 JSON 作为展示正文；失败原因只从
//! 本项目自有的信封字段或结果首行提取，且由调用方拥有并再次按行宽裁剪。
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
    edit,
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
        if (std.mem.eql(u8, name, "edit_file")) return .edit;
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
    display: ?@import("../core/background_status.zig").Caption = null,

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
    display: ?@import("../core/background_status.zig").Caption = null,

    pub fn fromExecution(result: r.Execution) Completion {
        const outcome: Outcome = if (result.canceled) .canceled else if (result.is_error) .failed else .success;
        const handoff = if (result.display) |display| display.action == .start and outcome == .success else false;
        return .{ .outcome = outcome, .file_stats = if (outcome == .success) result.file_stats else null, .duration_ms = if (handoff) null else result.duration_ms, .display = result.display };
    }
};

/// Bounded excerpt kept from an arbitrary failure body. The row clips it again to
/// the terminal width, so this is a memory bound, not a layout decision.
const reason_bytes = 512;

/// Owned, bounded, frontend-neutral reason for one failed call; the caller owns
/// the returned slice. The failed call's own text is shown as-is (read errors are
/// the runtime's raw error names); bash results are our own JSON envelope so only
/// its failure facts (timeout, signal, exit code, first stderr line) surface
/// instead of the raw envelope, and other tools expose their JSON error message
/// or the sanitized first line of their result. An empty body has nothing to show.
pub fn failureReason(a: std.mem.Allocator, kind: Kind, result: r.Execution) !?[]const u8 {
    if (!result.is_error or result.canceled) return null;
    if (kind == .read) return try excerpt(a, result.text);
    if (result.cleanup_failed) return try a.dupe(u8, "cleanup failed");
    if (kind == .bash) return try bashReason(a, result.text) orelse try a.dupe(u8, "command failed");
    if (try jsonError(a, result.text)) |message| return message;
    return excerpt(a, result.text);
}

/// Other executors answer with our own `{"error": ...}` envelope. Return the
/// message alone so a row never shows the envelope itself.
fn jsonError(a: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;
    var parsed = std.json.parseFromSlice(std.json.Value, a, trimmed, .{ .allocate = .alloc_if_needed, .max_value_len = 1024 * 1024 }) catch return null;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |map| map,
        else => return null,
    };
    const message = if (object.get("error")) |value| switch (value) {
        .string => |line| line,
        else => "",
    } else "";
    return excerpt(a, message);
}

/// bash results are the executor's JSON envelope. Only its structured failure
/// facts become a reason; a synthetic or malformed body never reaches a row.
fn bashReason(a: std.mem.Allocator, text: []const u8) !?[]const u8 {
    // The envelope is our own bash result: stdout/stderr may legitimately be
    // larger than the old 1 MiB string cap, and parsing must still see the
    // exit code and first lines.
    var parsed = std.json.parseFromSlice(std.json.Value, a, text, .{ .allocate = .alloc_if_needed }) catch return null;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |map| map,
        else => return null,
    };
    if (object.get("timed_out")) |value| switch (value) {
        .bool => |flag| if (flag) return try a.dupe(u8, "timed out"),
        else => {},
    };
    if (object.get("signal")) |value| switch (value) {
        .integer => |number| {
            if (signalLabel(number)) |label| return try std.fmt.allocPrint(a, "signal {d} ({s})", .{ number, label });
            return try std.fmt.allocPrint(a, "signal {d}", .{number});
        },
        else => {},
    };
    const code: ?i64 = if (object.get("exit_code")) |value| switch (value) {
        .integer => |number| number,
        else => null,
    } else null;
    if (code == null or code.? == 0) return null;
    const stderr = if (object.get("stderr")) |value| switch (value) {
        .string => |body| body,
        else => "",
    } else "";
    const stdout = if (object.get("stdout")) |value| switch (value) {
        .string => |body| body,
        else => "",
    } else "";
    const lines = nonEmptyLines(stderr);
    if (lines.first) |first_raw| {
        const first = try excerpt(a, first_raw);
        defer if (first) |value| a.free(value);
        if (first) |value| {
            if (lines.last) |last_raw| if (!std.mem.eql(u8, first_raw, last_raw)) {
                const last = try excerpt(a, last_raw);
                defer if (last) |item| a.free(item);
                if (last) |item| if (!std.mem.eql(u8, value, item))
                    return try std.fmt.allocPrint(a, "exit {d}: {s} ... {s}", .{ code.?, value, item });
            };
            return try std.fmt.allocPrint(a, "exit {d}: {s}", .{ code.?, value });
        }
    }
    // No printable stderr line: stdout is only a fallback diagnostic, clearly
    // labelled so it can never pass for the error channel.
    if (try excerpt(a, stdout)) |line| {
        defer a.free(line);
        return try std.fmt.allocPrint(a, "exit {d} (stderr empty); stdout: {s}", .{ code.?, line });
    }
    return try std.fmt.allocPrint(a, "exit {d} (stderr empty)", .{code.?});
}

/// Common signal names whose numbers are identical on Linux and macOS. Other
/// signals stay numeric instead of being guessed.
fn signalLabel(number: i64) ?[]const u8 {
    return switch (number) {
        2 => "SIGINT",
        9 => "SIGKILL",
        11 => "SIGSEGV",
        13 => "SIGPIPE",
        15 => "SIGTERM",
        else => null,
    };
}

const LinePair = struct { first: ?[]const u8 = null, last: ?[]const u8 = null };

fn nonEmptyLines(body: []const u8) LinePair {
    var first: ?[]const u8 = null;
    var last: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        if (first == null) first = line;
        last = line;
    }
    return .{ .first = first, .last = last };
}

/// Sanitized, single-line, bounded excerpt of a failure body. Null when nothing
/// printable remains.
fn excerpt(a: std.mem.Allocator, body: []const u8) !?[]const u8 {
    const text = std.mem.trimStart(u8, body, " \t\r\n");
    if (text.len == 0) return null;
    const prefix = try clean.sanitizePrefix(a, text, reason_bytes);
    defer a.free(prefix.text);
    const end = std.mem.indexOfAny(u8, prefix.text, "\r\n") orelse prefix.text.len;
    const line = std.mem.trim(u8, prefix.text[0..end], " \t");
    if (line.len == 0) return null;
    const out = try a.dupe(u8, line);
    for (out) |*byte| {
        if (byte.* == '\t') byte.* = ' ';
    }
    return out;
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
