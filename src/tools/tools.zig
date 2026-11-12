//! ThinAgent 内置工具层：定义工具 schema、解析并校验模型参数、执行已授权的动作。
//! 参数解析发生在授权之前；文件、命令与 memory 的真实副作用只在 execute 中产生。
//! bash 在 prepare 里做危险命令分类。命中的命令带 explicit_denial，Runtime 逐次询问。

const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
// Reserved legacy path: no preference reader/writer remains.
const settings = struct {
    const file_name = "settings.json";
    const relative_path = ".thin/settings.json";
};
const mem = @import("memory.zig");
const process = @import("../platform/process.zig");
const j = @import("../util/json.zig");
const runtime = @import("../core/runtime.zig");
const command_risk = @import("command_risk.zig");
const decision = @import("../core/decision.zig");
const image = @import("../core/image.zig");
const image_file = @import("image_file.zig");
const text_edit = @import("text_edit.zig");
const subagent = @import("../core/subagent.zig");
const background = @import("../core/background.zig");
const Title = @import("../core/session_metadata.zig").Title;

/// Foreground bash description. The background variant appends its own sentence
/// so a child Tools without a service never advertises background capability.
const bash_description = "Run bash in the startup project; cwd changes do not persist. With decision review disabled, ordinary commands run without approval prompts; classified high-risk commands require explicit approval each time. Denial means no execution. timeout_ms defaults to 5 minutes. stdout and stderr are captured in full.";

/// 暴露给模型的工具 schema 列表；顺序是对外契约（测试依赖 read_file 在 0、memory 在 3）。
pub const schemas = [_]p.ToolSchema{
    .{
        .name = "read_file",
        .description = "Read a local UTF-8 file. Relative paths start in the startup project; absolute paths and ../ may read outside it. Protected credentials and symlinks remain denied. offset is a zero-based BYTE offset; limit is a BYTE count, not lines. Mid-character starts round back at most 3 bytes; returned offset is the actual start. When truncated, use returned next_offset as the next call's offset.",
        .parameters_json =
        \\{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1}},"required":["path"],"additionalProperties":false}
        ,
    },
    .{
        .name = "write_file",
        .description = "Atomically write UTF-8 inside the startup project after host validation. Read relevant content before replacing it. Parent directory must exist; overwrite=true is required to replace a file. Denied writes make no change.",
        .parameters_json =
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"overwrite":{"type":"boolean"}},"required":["path","content"],"additionalProperties":false}
        ,
    },
    .{
        .name = "bash",
        .description = bash_description,
        .parameters_json =
        \\{"type":"object","properties":{"command":{"type":"string"},"timeout_ms":{"type":"integer","minimum":1}},"required":["command"],"additionalProperties":false}
        ,
    },
    .{
        .name = "memory",
        .description = "Store explicit durable project facts or reusable preferences, not transcripts or temporary progress. list returns one page of the core/index; use offset and limit to page. read returns content and version. Writes/deletes remain subject to host validation and limits. Create without expected_version; update/delete use read's version as expected_version. On conflict, reread; never overwrite blindly. topic core is startup core memory; other topics are ASCII slugs.",
        .parameters_json =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["list","read","write","delete"]},"topic":{"type":"string"},"content":{"type":"string"},"expected_version":{"type":["string","null"]},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1}},"required":["action"],"additionalProperties":false}
        ,
    },
};

// The configured reviewer, not the legacy shell classifier, owns the extra
// command-confirmation decision. These static variants add no prompt allocation
// and preserve tool IDs, order and parameter schemas.
const decision_bash_description = "Run bash in the startup project; cwd changes do not persist. The configured reviewer's ask=true requires approval for this call; ask=false removes the extra command-approval prompt. Review decides only whether to ask. Unavailable or invalid review pauses without executing. Denial means no execution. timeout_ms uses the host default when omitted; built-in default is 5 minutes. Hard validation and cancellation apply. stdout and stderr are captured in full.";

/// Background variants only appear when the host supplied a background service
/// to a root Tools. They state that the bounded timeout covers startup only, so
/// the command timeout is not mistaken for the lifetime of a handed-off service.
const background_bash_description = bash_description ++ " background=true starts a managed service in this Thin instance: the call returns after a bounded startup wait with an id; timeout_ms bounds only that startup wait, not how long the service keeps running. For long output needing later inspection, use background=true and read background.logs by offset. Manage it with the background tool.";
const decision_background_bash_description = decision_bash_description ++ " background=true starts a managed service in this Thin instance: timeout_ms bounds only the startup wait; after handoff the service keeps running until it is stopped or Thin exits. For long output needing later inspection, use background=true and read background.logs by offset. Manage it with the background tool.";
const bash_background_parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string"},"timeout_ms":{"type":"integer","minimum":1},"background":{"type":"boolean"}},"required":["command"],"additionalProperties":false}
;

/// One management tool, appended after every other root tool. It exists only
/// for a root Tools with a background service and no child channel.
const background_schema: p.ToolSchema = .{
    .name = "background",
    .description = "Manage background commands started with bash background=true in this Thin instance. list pages services by launch order (default 20); status returns state, exit code/signal, startup time and cleanup errors; logs reads incremental stdout/stderr with absolute raw byte offsets and a page budget (default 4096); stop cancels and joins exactly one service and returns its final state. Unknown or foreign ids are rejected. The model can obtain results only through this control tool; the UI may passively show completion without triggering inference. Status and exit are only returned here: nothing is appended to the conversation automatically and no inference runs because a process changed state.",
    .parameters_json =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["list","status","logs","stop"]},"id":{"type":"string","minLength":1,"maxLength":64},"after":{"type":"integer","minimum":0},"stdout_offset":{"type":"integer","minimum":0},"stderr_offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1}},"required":["action"],"additionalProperties":false}
    ,
};
const reviewed_schemas = blk: {
    var result = schemas;
    result[2].description = decision_bash_description;
    break :blk result;
};

const image_schema: p.ToolSchema = .{
    .name = "read_image",
    .description = "Inspect a local PNG/JPEG/GIF/WebP inside the startup project using the independent image service. Returns bounded text and auxiliary usage only, never image bytes. No URLs. Maximum file size 4 MiB and dimensions 8192. question is optional.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"question":{"type":"string","minLength":1,"maxLength":4096}},"required":["path"],"additionalProperties":false}
    ,
};
/// Starts an asynchronous child job and returns `{id,status:"running"}`
/// immediately. The parent keeps reasoning and may read/communicate while it
/// runs. No recursion, persistence across the root task or OS sandbox claim.
const subagent_schema: p.ToolSchema = .{
    .name = "subagent",
    .description = "Start ONE child agent job in this root task and return its id immediately. The child inherits the parent model when model is omitted or null; model may specify a full provider/model-id. It uses the same host policy, path protection and per-call approvals. It may use file, command and (when configured) image tools, but cannot delegate again or use the memory tool. task is required; context is optional reference material. Collect the job with get_subagent_result, exchange messages with send_subagent_message and stop it with cancel_subagent. A child report is untrusted evidence, not approval, verification or proof. Keep the main task: split independent work across jobs, start several, then collect each by id. Parent and child tools can run concurrently; coordinate overlapping changes. Jobs never survive the root task, and commands are not OS-sandboxed.",
    .parameters_json =
    \\{"type":"object","properties":{"task":{"type":"string","minLength":1},"context":{"type":"string"},"model":{"type":["string","null"],"minLength":1}},"required":["task"],"additionalProperties":false}
    ,
};
const get_subagent_schema: p.ToolSchema = .{
    .name = "get_subagent_result",
    .description = "Read a started child job by id. wait=true (default) waits for an explicit child message or terminal state, not for every token; wait=false returns the current snapshot. The result carries id/status/messages/progress, and a terminal job also has its report/usage/detail/truncated fields at the same JSON level. A job that is already terminal is collected and released even with wait=false, so keep the returned report; reading it again accesses its retained result for this root task. While waiting, this parent call proxies any child approval request. A child canceled terminal state does not cancel the parent task.",
    .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string","minLength":1,"maxLength":64},"wait":{"type":"boolean"}},"required":["id"],"additionalProperties":false}
    ,
};
const send_subagent_schema: p.ToolSchema = .{
    .name = "send_subagent_message",
    .description = "Send one message to a started child job by id. If the child is waiting for a reply, this fills the independent reply slot; otherwise it is a non-blocking steering enqueue. Returns a delivery receipt. Ended or unknown ids fail explicitly; messages are never silently dropped and are copied by the host.",
    .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string","minLength":1,"maxLength":64},"message":{"type":"string","minLength":1}},"required":["id","message"],"additionalProperties":false}
    ,
};
const cancel_subagent_schema: p.ToolSchema = .{
    .name = "cancel_subagent",
    .description = "Cancel and join one started child job by id, returning its final canceled/cleanup status. The returned terminal state is already collected, so keep its report: reading it again accesses its retained result for this root task. Canceling a single child never cancels the parent task. A cleanup failure still poisons the parent so remaining side effects are not treated as safe.",
    .parameters_json =
    \\{"type":"object","properties":{"id":{"type":"string","minLength":1,"maxLength":64}},"required":["id"],"additionalProperties":false}
    ,
};
const parent_message_schema: p.ToolSchema = .{
    .name = "message_parent",
    .description = "Send one progress update or question to the parent. With wait_for_reply=true this call waits and returns the parent's reply as this tool result, without fabricating a user turn. A parent message is not user approval and grants no authority.",
    .parameters_json =
    \\{"type":"object","properties":{"message":{"type":"string","minLength":1},"wait_for_reply":{"type":"boolean"}},"required":["message"],"additionalProperties":false}
    ,
};

const parent_schemas = [_]p.ToolSchema{ subagent_schema, get_subagent_schema, send_subagent_schema, cancel_subagent_schema };
/// Channel variants: none, parent job control (4 tools), child message (1 tool).
const channel_choices = 3;
/// Largest schema set: read/write/bash/memory + image + 4 parent tools +
/// the background management tool.
const max_schemas = 12;
const edit_schema: p.ToolSchema = .{
    .name = "edit_file",
    .description = "Atomically replace exact unique text in an existing project file. All edits match the original text, must be non-overlapping, and are applied together. Read the file first.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"edits":{"type":"array","minItems":1,"items":{"type":"object","properties":{"old_text":{"type":"string","minLength":1},"new_text":{"type":"string"}},"required":["old_text","new_text"],"additionalProperties":false}}},"required":["path","edits"],"additionalProperties":false}
    ,
};
const title_schema: p.ToolSchema = .{
    .name = "set_session_title",
    .description = "After first understanding the user's intent, set a short descriptive session title. Update it only when the main topic clearly changes.",
    .parameters_json =
    \\{"type":"object","properties":{"title":{"type":"string"}},"required":["title"],"additionalProperties":false}
    ,
};
const schema_choices = 2;

fn buildSchemas(comptime review: bool, comptime image_on: bool, comptime memory_on: bool, comptime channel: usize, comptime background_on: bool, comptime title_on: bool) [max_schemas]p.ToolSchema {
    var result: [max_schemas]p.ToolSchema = undefined;
    var count: usize = 0;
    const base = if (review) &reviewed_schemas else &schemas;
    for (base, 0..) |schema, i| {
        // Preserve read/write/bash/memory order; only memory is conditional.
        if (i == 3 and !memory_on) continue;
        if (i == 2 and background_on) {
            // Same name and index, but the parameters expose the optional
            // background dimension and the description explains startup-only
            // timeouts. A Tools without a service keeps the old schema bytes.
            result[count] = .{
                .name = schema.name,
                .description = if (review) decision_background_bash_description else background_bash_description,
                .parameters_json = bash_background_parameters_json,
            };
        } else result[count] = schema;
        count += 1;
    }
    if (image_on) {
        result[count] = image_schema;
        count += 1;
    }
    if (channel == 1) {
        for (parent_schemas) |schema| {
            result[count] = schema;
            count += 1;
        }
    } else if (channel == 2) {
        result[count] = parent_message_schema;
        count += 1;
    }
    // Appended last so every previous tool keeps its index.
    if (background_on) {
        result[count] = background_schema;
        count += 1;
    }
    if (title_on) {
        result[count] = title_schema;
        count += 1;
    }
    result[count] = edit_schema;
    return result;
}

// Static table of the small feature matrix. Slices point into read-only data, so
// a rebind never invalidates a previously handed-out schema slice.
const schema_table = blk: {
    @setEvalBranchQuota(160000);
    var table: [schema_choices][schema_choices][schema_choices][schema_choices][schema_choices][channel_choices][max_schemas]p.ToolSchema = undefined;
    for (0..schema_choices) |title_on| for (0..schema_choices) |background_on| for (0..schema_choices) |review| for (0..schema_choices) |image_on| for (0..schema_choices) |memory_on| for (0..channel_choices) |channel| {
        table[title_on][background_on][review][image_on][memory_on][channel] = buildSchemas(review == 1, image_on == 1, memory_on == 1, channel, background_on == 1, title_on == 1);
    };
    break :blk table;
};

fn schemaCount(image_on: bool, memory_on: bool, channel: usize, background_on: bool) usize {
    const channel_count: usize = switch (channel) {
        1 => parent_schemas.len,
        2 => 1,
        else => 0,
    };
    return 5 + @as(usize, @intFromBool(image_on)) + channel_count + @as(usize, @intFromBool(background_on)) - @as(usize, @intFromBool(!memory_on));
}

fn schemasWithTitle(review: bool, image_on: bool, memory_on: bool, channel: usize, background_on: bool, title_on: bool) []const p.ToolSchema {
    const set: *const [max_schemas]p.ToolSchema = &schema_table[@intFromBool(title_on)][@intFromBool(background_on)][@intFromBool(review)][@intFromBool(image_on)][@intFromBool(memory_on)][channel];
    return set[0 .. schemaCount(image_on, memory_on, channel, background_on) + @as(usize, @intFromBool(title_on))];
}

pub const ReadImage = struct { path: []const u8, question: []const u8 = image.default_question };
fn validateReadImage(r: ReadImage) !void {
    try validatePath(r.path);
    if (std.ascii.startsWithIgnoreCase(r.path, "http://") or std.ascii.startsWithIgnoreCase(r.path, "https://")) return error.InvalidImagePath;
    if (r.question.len == 0 or r.question.len > image.max_question_bytes or !std.unicode.utf8ValidateSlice(r.question) or std.mem.indexOfScalar(u8, r.question, 0) != null) return error.InvalidImageQuestion;
}

/// read_file 的解析结果；offset 为字节偏移，limit 为空时使用默认分页。
pub const Read = struct { path: []const u8, offset: u64 = 0, limit: ?usize = null };
/// write_file 的解析结果；覆盖已有文件必须显式设置 overwrite。
pub const Write = struct { path: []const u8, content: []const u8, overwrite: bool = false };
pub const EditFile = struct { path: []const u8, edits: []const text_edit.Edit };
/// bash 的解析结果；timeout_ms 为空时使用配置的默认超时。background=true
/// 只改变本次调用的执行方式：异步启动一个实例内托管服务。
pub const Bash = struct { command: []const u8, timeout_ms: ?u32 = null, background: bool = false };

/// memory 工具的解析结果；topic 为 core 或 ASCII slug，list 时不得携带其他字段。
pub const Memory = struct {
    /// 操作类型：list/read/write/delete。
    action: enum { list, read, write, delete },
    /// 目标主题；list 时必须为空。
    topic: ?[]const u8 = null,
    /// 写入内容，仅 write 使用。
    content: ?[]const u8 = null,
    /// 乐观并发版本（内容哈希）：write 更新与 delete 必须提供，create 必须为空。
    expected_version: ?[]const u8 = null,
    /// list 分页起点与每页条数。索引没有总大小上限，但每次只返回一页。
    offset: u32 = 0,
    limit: ?u32 = null,
};

/// 已解析且通过基本校验的工具动作；内部的切片指向解析时的 arena。
pub const Action = union(enum) {
    read_file: Read,
    read_image: ReadImage,
    write_file: Write,
    edit_file: EditFile,
    bash: Bash,
    background: background.Query,
    memory: Memory,
    subagent: subagent.Request,
    get_subagent_result: subagent.Query,
    send_subagent_message: subagent.Send,
    cancel_subagent: subagent.Cancel,
    message_parent: subagent.Message,
    set_session_title: Title,

    /// 生成展示给用户的授权描述；写入 memory 时附带完整内容，便于用户审阅后再批准。
    pub fn description(self: Action, a: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .read_file => |r| try std.fmt.allocPrint(a, "Read {s}", .{r.path}),
            .read_image => |r| try std.fmt.allocPrint(a, "Inspect image {s}", .{r.path[0..@min(r.path.len, 4096)]}),
            .write_file => |w| try std.fmt.allocPrint(a, "{s} {s} ({d} bytes)", .{
                if (w.overwrite) "Write/replace" else "Create", w.path, w.content.len,
            }),
            .edit_file => |e| try std.fmt.allocPrint(a, "Edit {s} ({d} edits)", .{ e.path, e.edits.len }),
            .bash => |b| try std.fmt.allocPrint(a, "Run bash{s}: {s}", .{ if (b.background) " (background service)" else "", b.command }),
            .background => |q| if (q.id) |id|
                try std.fmt.allocPrint(a, "Background {s} {s}", .{ q.action.name(), id })
            else
                try std.fmt.allocPrint(a, "Background {s}", .{q.action.name()}),
            // create 与 update 的区别仅在于 expected_version 是否为空。
            .memory => |m| if (m.action == .write)
                try std.fmt.allocPrint(a, "Memory {s}: {s} ({d} bytes)\n{s}", .{ if (m.expected_version == null) "create" else "update", m.topic.?, m.content.?.len, m.content.? })
            else
                try std.fmt.allocPrint(a, "Memory {s}: {s}", .{ @tagName(m.action), m.topic orelse "index" }),
            // Display-only bounded task summary; never the context body.
            .subagent => |request| try std.fmt.allocPrint(a, "Delegate subagent task: {s}{s}", .{
                summaryText(request.task, 240),
                if (request.task.len > 240) "..." else "",
            }),
            // Job-control captions expose only the bounded id, never messages.
            .get_subagent_result => |query| try std.fmt.allocPrint(a, "Get subagent result {s}", .{query.id}),
            .send_subagent_message => |message| try std.fmt.allocPrint(a, "Send subagent message {s}", .{message.id}),
            .cancel_subagent => |request| try std.fmt.allocPrint(a, "Cancel subagent {s}", .{request.id}),
            // Child status only; the parent must not see the message body in a
            // generic row and no separate panel is introduced here.
            .message_parent => try a.dupe(u8, "Message parent"),
            .set_session_title => |title| try std.fmt.allocPrint(a, "Set session title: {s}", .{title.text()}),
        };
    }
};

/// Bounded, UTF-8-aligned display slice used for tool titles.
fn summaryText(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return text[0..end];
}

/// Parse and validate before requesting authorization. a is a short-lived arena.
/// 在请求授权前解析并校验参数；a 是短生命周期 arena，返回值中的字符串都归它所有。
pub fn parse(a: std.mem.Allocator, name: []const u8, arguments: []const u8, limits: cfg.Limits) !Action {
    // 严格模式：拒绝未知字段（如伪造的 trust），并让字符串复制进 arena，不借用输入缓冲。
    const opts: std.json.ParseOptions = .{ .allocate = .alloc_always, .ignore_unknown_fields = false };
    if (std.mem.eql(u8, name, "set_session_title")) {
        const args = try std.json.parseFromSliceLeaky(struct { title: []const u8 }, a, arguments, opts);
        const title = Title.fromText(args.title);
        if (title.text().len == 0) return error.InvalidSessionTitle;
        return .{ .set_session_title = title };
    }
    if (std.mem.eql(u8, name, "read_image")) {
        const args = try std.json.parseFromSliceLeaky(ReadImage, a, arguments, opts);
        try validateReadImage(args);
        return .{ .read_image = args };
    }
    if (std.mem.eql(u8, name, "read_file")) {
        const args = try std.json.parseFromSliceLeaky(Read, a, arguments, opts);
        try validateReadPath(args.path);
        // 未指定 limit 时用配置上限；0 或超过上限都拒绝，避免单次读取撑爆上下文。
        if (args.limit) |limit| if (limit == 0) return error.InvalidReadLimit;
        return .{ .read_file = args };
    }

    if (std.mem.eql(u8, name, "edit_file")) {
        const args = try std.json.parseFromSliceLeaky(EditFile, a, arguments, opts);
        try validatePath(args.path);
        if (args.edits.len == 0) return error.EmptyEdits;
        for (args.edits) |edit| {
            if (edit.old_text.len == 0) return error.EmptyOldText;
            for ([_][]const u8{ edit.old_text, edit.new_text }) |text| {
                if (!std.unicode.utf8ValidateSlice(text) or std.mem.findScalar(u8, text, 0) != null) return error.InvalidText;
            }
        }
        return .{ .edit_file = args };
    }

    if (std.mem.eql(u8, name, "write_file")) {
        const args = try std.json.parseFromSliceLeaky(Write, a, arguments, opts);
        try validatePath(args.path);
        // 写入内容必须是合法 UTF-8 且不含 NUL，避免写出二进制或损坏的文本。
        if (!std.unicode.utf8ValidateSlice(args.content) or std.mem.findScalar(u8, args.content, 0) != null)
            return error.InvalidText;
        return .{ .write_file = args };
    }

    if (std.mem.eql(u8, name, "bash")) {
        const args = try std.json.parseFromSliceLeaky(Bash, a, arguments, opts);
        // 命令长度限制为 32KB 且不允许 NUL；超时必须在 (0, 配置上限] 之内。
        if (args.command.len == 0 or std.mem.findScalar(u8, args.command, 0) != null)
            return error.InvalidCommand;
        const timeout = args.timeout_ms orelse limits.command_timeout_ms;
        if (timeout == 0) return error.InvalidCommandTimeout;
        return .{ .bash = args };
    }

    if (std.mem.eql(u8, name, "background")) {
        // action-specific strictness (irrelevant fields, quoted/numeric coercion,
        // cursors, id charset) lives in the pure core raw parser; Tools only adds
        // availability and maps every contract failure to its own error code.
        const query = background.parseQuery(a, arguments) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidBackgroundQuery,
        };
        return .{ .background = query };
    }

    if (std.mem.eql(u8, name, "subagent")) {
        const args = try std.json.parseFromSliceLeaky(subagent.Request, a, arguments, opts);
        try subagent.validate(args);
        return .{ .subagent = args };
    }

    if (std.mem.eql(u8, name, "get_subagent_result")) {
        const args = try std.json.parseFromSliceLeaky(subagent.Query, a, arguments, opts);
        try subagent.validateQuery(args);
        return .{ .get_subagent_result = args };
    }

    if (std.mem.eql(u8, name, "send_subagent_message")) {
        const args = try std.json.parseFromSliceLeaky(subagent.Send, a, arguments, opts);
        try subagent.validateSend(args);
        return .{ .send_subagent_message = args };
    }

    if (std.mem.eql(u8, name, "cancel_subagent")) {
        const args = try std.json.parseFromSliceLeaky(subagent.Cancel, a, arguments, opts);
        try subagent.validateCancel(args);
        return .{ .cancel_subagent = args };
    }

    if (std.mem.eql(u8, name, "message_parent")) {
        const args = try std.json.parseFromSliceLeaky(subagent.Message, a, arguments, opts);
        try subagent.validateMessage(args);
        return .{ .message_parent = args };
    }

    if (std.mem.eql(u8, name, "memory")) {
        const args = try std.json.parseFromSliceLeaky(Memory, a, arguments, opts);
        // list 不接受 topic/content/版本号，保持调用形状严格。
        if (args.action == .list) {
            if (args.topic != null or args.content != null or args.expected_version != null)
                return error.InvalidMemoryArguments;
            if (args.limit) |limit| if (limit == 0 or limit > mem.max_list_limit) return error.InvalidMemoryArguments;
        } else {
            if (args.offset != 0 or args.limit != null) return error.InvalidMemoryArguments;
            // 非 list 操作都必须带合法 topic（core 或 ASCII slug）。
            const topic = args.topic orelse return error.MissingMemoryTopic;
            mem.validTopic(topic) catch return error.InvalidMemoryTopic;
            // 写入：按 core 或分片分别限制大小，并校验 UTF-8 与 NUL。
            if (args.action == .write) {
                const content = args.content orelse return error.MissingMemoryContent;
                if (!std.unicode.utf8ValidateSlice(content) or std.mem.findScalar(u8, content, 0) != null)
                    return error.InvalidText;
            } else if (args.content != null) return error.InvalidMemoryArguments;
            // read 不带版本号；delete 必须带读取时拿到的版本（CAS 条件），否则拒绝。
            if (args.action == .read and args.expected_version != null) return error.InvalidMemoryArguments;
            if (args.action == .delete and args.expected_version == null) return error.MissingMemoryVersion;
        }
        return .{ .memory = args };
    }

    return error.UnknownTool;
}

/// Text reads may leave the project; syntax and resource limits still apply.
fn validateReadPath(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or std.mem.findScalar(u8, path, 0) != null)
        return error.InvalidPath;
}

/// Writes and image reads retain their rooted path policy.
fn validatePath(path: []const u8) !void {
    try validateReadPath(path);
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.PathEscape;
}

/// 工具执行结果，直接来自 runtime 模块（text、is_error、canceled 等标记）。
pub const Execution = runtime.Execution;

/// 工具集合：绑定启动项目根目录、memory 存储、配置与受限的命令环境。
pub const Tools = struct {
    /// 启动项目根目录；所有文件路径都相对它解析。
    root: *fs.Root,
    /// 项目内 memory 存储（.thin/memory）。
    memory: *mem.Store,
    /// 运行时配置，包含各类上限与超时。
    config: *const cfg.Config,
    /// 传给 bash 的环境变量（已经过 commandEnvironment 过滤）。
    environment: *const std.process.Environ.Map,
    /// 由应用层传入的认证文件 realPath；与 Root.path 使用同一真实路径空间，
    /// 即使启动目录是 HOME 或 HOME 本身是别名，也不能通过模型文件工具泄露凭证。
    auth_path: ?[]const u8 = null,
    /// Explicit opt-in; no service means no image schema and no file access.
    image: ?image.Service = null,
    /// Optional in-process child service (parent Tools). Null hides the four
    /// parent job tools and rejects forged calls at prepare and direct execute;
    /// child Tools are built without one, so recursive delegation fails there.
    subagent: ?subagent.Service = null,
    /// Optional instance-owned background registry. Only a root Tools with this
    /// service and no child channel exposes bash background=true and the
    /// management tool. It is a separate capability from subagents.
    background: ?background.Service = null,
    /// Child-only channel. It exposes exactly the message_parent tool; it cannot
    /// reach parent jobs, permissions, Runtime or Memory.
    parent_channel: ?subagent.ParentChannel = null,
    /// False hides the memory schema and rejects forged memory calls (child Tools).
    allow_memory: bool = true,
    /// Only a Session-owned root App enables the title capability.
    session_title: ?Title = null,

    /// Hidden capabilities are an execution boundary, not only a schema detail.
    /// The parent surface exists exactly when the host supplied a service; there
    /// is no separate persisted switch.
    fn subagentActive(self: *Tools) bool {
        return self.subagent != null;
    }

    fn parentChannelActive(self: *Tools) bool {
        return self.parent_channel != null;
    }

    /// A child Tools never gets a background registry, and a forged service on
    /// a child channel still must not unlock background start or management:
    /// only the accepted root may own instance-level services.
    fn backgroundActive(self: *Tools) bool {
        return self.background != null and self.parent_channel == null;
    }

    fn isBackgroundManaged(name: []const u8) bool {
        return std.mem.eql(u8, name, "background");
    }

    fn isParentTool(name: []const u8) bool {
        return std.mem.eql(u8, name, "subagent") or std.mem.eql(u8, name, "get_subagent_result") or
            std.mem.eql(u8, name, "send_subagent_message") or std.mem.eql(u8, name, "cancel_subagent");
    }

    fn channelChoice(self: *Tools) usize {
        if (self.subagentActive()) return 1;
        if (self.parentChannelActive()) return 2;
        return 0;
    }

    fn checkAvailableActions(self: *Tools, action: Action) !void {
        switch (action) {
            .bash => |b| if (b.background and !self.backgroundActive()) return error.BackgroundDisabled,
            .background => if (!self.backgroundActive()) return error.BackgroundDisabled,
            .subagent => |request| {
                if (!self.subagentActive()) return error.SubagentDisabled;
                try subagent.validate(request);
            },
            .get_subagent_result => |query| {
                if (!self.subagentActive()) return error.SubagentDisabled;
                try subagent.validateQuery(query);
            },
            .send_subagent_message => |message| {
                if (!self.subagentActive()) return error.SubagentDisabled;
                try subagent.validateSend(message);
            },
            .cancel_subagent => |request| {
                if (!self.subagentActive()) return error.SubagentDisabled;
                try subagent.validateCancel(request);
            },
            .message_parent => |message| {
                if (!self.parentChannelActive()) return error.SubagentMessageDisabled;
                try subagent.validateMessage(message);
            },
            .memory => if (!self.allow_memory) return error.MemoryDisabled,
            .set_session_title => |title| {
                if (self.session_title == null or self.parent_channel != null) return error.SessionTitleDisabled;
                if (title.text().len == 0) return error.InvalidSessionTitle;
            },
            else => {},
        }
    }

    fn checkImageAction(self: *Tools, action: Action) !void {
        if (action == .read_image) {
            const service = self.image orelse return error.ImageDisabled;
            try service.checkReady();
            try validateReadImage(action.read_image);
        }
    }

    /// Both preparation and direct execution use the same anchored path policy.
    fn checkFileAction(self: *Tools, a: std.mem.Allocator, action: Action) !void {
        const path = switch (action) {
            .read_file => |read| read.path,
            .read_image => |read| read.path,
            .write_file => |write| write.path,
            .edit_file => |edit| edit.path,
            else => return,
        };
        if (action == .read_file) {
            try validateReadPath(path);
            if (action.read_file.limit) |limit| if (limit == 0) return error.InvalidReadLimit;
            // Text policy is applied to actual descriptors below, not a resolve
            // against root.path, which can name a different parent after rename.
            return;
        }
        const is_write = action == .write_file or action == .edit_file;
        const absolute = try std.fs.path.resolve(a, &.{ self.root.path, path });
        defer a.free(absolute);
        const relative = try self.root.relative(path);
        // 会话记录可作为普通只读输入，但不允许文件工具篡改自己的留档。
        // 文本读取允许项目外路径；仍保留 OS 权限、NOFOLLOW、UTF-8 与大小限制。
        // 跳过点段和重复分隔符，保证绝对/相对路径别名使用同一规则。
        var parts = std.mem.tokenizeScalar(u8, relative, '/');
        var in_thin = false;
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".")) continue;
            if (!in_thin) {
                if (!std.mem.eql(u8, part, ".thin")) break;
                in_thin = true;
            } else {
                in_thin = false; // A second non-dot component exists.
                if (is_write and (std.mem.eql(u8, part, mem.directory_name) or std.mem.eql(u8, part, "mem"))) return error.UseMemoryTool;
                // Exact project settings path only; ignore dot/slash aliases.
                if (std.mem.eql(u8, part, settings.file_name)) {
                    var exact = true;
                    while (parts.next()) |rest| {
                        if (!std.mem.eql(u8, rest, ".")) {
                            exact = false;
                            break;
                        }
                    }
                    if (exact) return error.ProtectedSettingsFile;
                }
                // 新档案放在 sessions；旧 logs 留档仍受保护，但不再写入或自动搬迁。
                // 会话记录允许只读导入，但禁止模型写入/篡改自己的留档。
                if (std.mem.eql(u8, part, "sessions") or std.mem.eql(u8, part, "logs")) {
                    if (is_write) return error.ProtectedSessionFile;
                    break;
                }
                break;
            }
        }
        // Writing the .thin parent itself must not replace the Memory namespace.
        if (in_thin and is_write) return error.UseMemoryTool;
        const protected = self.auth_path orelse return;
        if (std.mem.eql(u8, absolute, protected)) return error.ProtectedAuthFile;
    }

    fn textReadGuard(self: *Tools) fs.Root.ReadGuard {
        return .{ .context = self, .check_fn = checkTextReadTarget };
    }

    /// Parent/name covers absent protected leaves; dev+inode also covers an
    /// already-open leaf (including aliases). Never reads protected contents.
    fn matchesReadTarget(target: fs.Root.Parent, fd: ?c_int, protected: fs.Root.Parent) !bool {
        if (std.mem.eql(u8, target.name, protected.name) and try fs.sameObject(target.fd, protected.fd)) return true;
        const opened = fd orelse return false;
        return fs.sameObjectAt(opened, protected.fd, protected.name) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
    }

    fn checkTextReadTarget(raw: *anyopaque, target: fs.Root.Parent, fd: ?c_int) !void {
        const self: *Tools = @ptrCast(@alignCast(raw));
        // Project settings follow the launch inode even when its pathname was
        // replaced. Auth uses the same component/dirfd semantics as the reader.
        var project_settings: ?fs.Root.Parent = self.root.parent(".thin/" ++ settings.file_name) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (project_settings) |*parent_| parent_.deinit();
        if (project_settings) |parent_| {
            if (try matchesReadTarget(target, fd, parent_)) return error.ProtectedSettingsFile;
        }
        if (self.auth_path) |path| {
            var auth = self.root.readParent(path) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };
            defer auth.deinit();
            if (try matchesReadTarget(target, fd, auth)) return error.ProtectedAuthFile;
        }
    }

    /// 把 Tools 包装成 runtime.Executor，供运行时调度 prepare 与 execute。
    pub fn executor(self: *Tools) runtime.Executor {
        return .{
            .context = self,
            .schemas = schemasWithTitle(self.config.decisionActive(), self.image != null, self.allow_memory, self.channelChoice(), self.backgroundActive(), self.session_title != null and self.parent_channel == null),
            .prepare_fn = prepare,
            .execute_fn = executePrepared,
            .preview_write_fn = previewWrite,
            .begin_task_fn = beginTask,
            .before_finish_fn = beforeFinish,
            .end_task_fn = endTask,
        };
    }

    /// Accepted-task hook. A child Tools carries no service, so it never resets
    /// shared host state. The accepted-root cancellation token is forwarded for
    /// job parent linking, never a local tool-call token.
    fn beginTask(context_: *anyopaque, cancel: *const p.Cancellation) void {
        const self: *Tools = @ptrCast(@alignCast(context_));
        if (self.subagent) |service| service.beginTask(cancel);
    }

    /// Normal-stop hook: forward to the host service so active/uncollected jobs
    /// produce one bounded context hint. Runtime owns the reminder budget and
    /// the stable-history copy.
    fn beforeFinish(context_: *anyopaque, a: std.mem.Allocator, cancel: *const p.Cancellation) !?[]const u8 {
        const self: *Tools = @ptrCast(@alignCast(context_));
        // A handed-off service is not stopped at normal stop: only its health
        // (including asynchronous cleanup failure) is checked so the root task
        // cannot report success after an unrecoverable cleanup failure.
        if (self.backgroundActive()) if (self.background) |service| try service.checkReady();
        const service = self.subagent orelse return null;
        return service.beforeFinish(a, cancel);
    }

    /// Unified accepted-task cleanup: cancel/join or retain child jobs before
    /// Runtime joins the watchdog and finalizes Memory. Background services are
    /// instance-owned and survive this root task; only their health is checked.
    fn endTask(context_: *anyopaque, cancel: *const p.Cancellation) !void {
        const self: *Tools = @ptrCast(@alignCast(context_));
        if (self.subagent) |service| try service.endTask(cancel);
        if (self.backgroundActive()) if (self.background) |service| try service.checkReady();
    }

    fn previewWrite(context_: *anyopaque, a: std.mem.Allocator, path: []const u8, cancel: *const p.Cancellation) !?@import("../core/write_preview.zig").Baseline {
        const self: *Tools = @ptrCast(@alignCast(context_));
        if (cancel.isRequested()) return null;
        try self.checkFileAction(a, .{ .write_file = .{ .path = path, .content = "", .overwrite = true } });
        const bytes = self.root.readBinaryGuarded(a, path, @import("../util/line_stats.zig").max_bytes, self.textReadGuard()) catch |err| switch (err) {
            error.FileNotFound => return @import("../core/write_preview.zig").Baseline.fromBytes(a, ""),
            else => return null,
        };
        defer {
            std.crypto.secureZero(u8, bytes);
            a.free(bytes);
        }
        if (cancel.isRequested()) return null;
        return @import("../core/write_preview.zig").Baseline.fromBytes(a, bytes);
    }

    /// 解析并做路径校验，生成待授权的 Prepared；此阶段不产生任何副作用。
    fn prepare(context_: *anyopaque, a: std.mem.Allocator, call: p.ToolCall) !runtime.Prepared {
        const self: *Tools = @ptrCast(@alignCast(context_));
        // Names the model was never offered must not become executable actions.
        // Reject before parsing or allocating anything.
        if (std.mem.eql(u8, call.name, "set_session_title") and (self.session_title == null or self.parent_channel != null)) return error.SessionTitleDisabled;
        if (!self.allow_memory and std.mem.eql(u8, call.name, "memory")) return error.MemoryDisabled;
        if (!self.subagentActive() and isParentTool(call.name)) return error.SubagentDisabled;
        if (!self.parentChannelActive() and std.mem.eql(u8, call.name, "message_parent")) return error.SubagentMessageDisabled;
        // Pure availability boundary: a child Tools (parent channel) and any
        // Tools without a registry must reject the management tool before parse.
        if (isBackgroundManaged(call.name) and !self.backgroundActive()) return error.BackgroundDisabled;
        const action = try a.create(Action);
        action.* = try parse(a, call.name, call.arguments, self.config.limits);
        // Forged background arguments fail here as well as in direct execute.
        try self.checkAvailableActions(action.*);
        try self.checkImageAction(action.*);
        try self.checkFileAction(a, action.*);
        // 危险 bash 在授权前打标。Runtime 看到 explicit_denial 后逐次询问。
        var description = try action.description(a);
        const risk = if (action.* == .bash) command_risk.classify(action.bash.command) else null;
        const denial: ?[]const u8 = if (risk) |finding| blk: {
            description = try std.fmt.allocPrint(a, "DANGEROUS bash ({s}). Explicit approval is required each time; choose Allow once or Deny in the confirmation popup.\n{s}", .{ finding.label, description });
            break :blk try std.fmt.allocPrint(a, "Dangerous bash command was not executed ({s}). High-risk bash needs an explicit user allow each time.", .{finding.label});
        } else null;
        const review: ?decision.Input = switch (action.*) {
            .bash => |b| .{ .command = .{
                .command = b.command,
                .risk = if (risk) |finding| finding.label else null,
            } },
            else => null,
        };
        const status = @import("../core/background_status.zig");
        const display: ?status.Caption = switch (action.*) {
            .bash => |b| if (b.background) .{ .action = .start, .command = self.background.?.caption(b.command) } else null,
            .background => |q| .{
                .action = switch (q.action) {
                    .list => .list,
                    .status => .status,
                    .logs => .logs,
                    .stop => .stop,
                },
                .id = if (q.id) |id| status.Id.from(id) else null,
                .command = if (q.id) |id| if (self.background) |service| service.command(id) else null else null,
            },
            else => null,
        };
        return .{ .payload = action, .description = description, .explicit_denial = denial, .decision_input = review, .display = display };
    }

    /// 从 prepare 生成的 payload 取回 Action 并执行；payload 指向同一个 arena 中的 Action。
    fn executePrepared(context_: *anyopaque, a: std.mem.Allocator, prepared: runtime.Prepared, cancel: *const p.Cancellation) !Execution {
        const self: *Tools = @ptrCast(@alignCast(context_));
        const action: *const Action = @ptrCast(@alignCast(prepared.payload));
        return self.execute(a, action.*, cancel);
    }

    /// Explicit approval is a Runtime responsibility. Never call this for an
    /// operation requiring approval before it is granted. This function does no terminal I/O.
    /// 按 Action 执行具体副作用，并把结果编码为 JSON 文本；本函数不做任何终端输入输出。
    pub fn execute(self: *Tools, a: std.mem.Allocator, action: Action, cancel: *const p.Cancellation) !Execution {
        // Readiness/poison and argument guards are pure and precede all I/O.
        try self.checkImageAction(action);
        try self.checkAvailableActions(action);
        // An instance-level background cleanup failure poisons EVERY ordinary
        // tool execution, not only background calls: side effects are no longer
        // known-safe. The service health check never stops a handed-off job.
        if (self.backgroundActive()) if (self.background) |service| try service.checkReady();
        // 执行前已取消则直接返回，不触碰磁盘或子进程。
        if (cancel.isRequested()) return .{ .text = "Canceled before execution", .is_error = true, .canceled = true };

        // 直接执行入口也校验路径，避免绕过 prepare。危险 bash 的拦截在 Runtime 授权，
        // 不在这里重复拒绝：能进入 execute 说明本次调用已经过明确批准。bash 仍不是沙箱。
        try self.checkFileAction(a, action);

        var value = j.object(a);
        switch (action) {
            .set_session_title => |title| {
                try j.put(a, &value, "title", j.str(title.text()));
                const encoded = try j.encode(a, value);
                self.session_title = title;
                return .{ .text = encoded };
            },
            .read_image => |r| {
                if (cancel.isRequested()) return error.Canceled;
                const picture = try image_file.load(a, self.root, r.path);
                defer a.free(picture.data);
                if (cancel.isRequested()) return error.Canceled;
                const output = try self.image.?.inspect(a, .{ .image = picture, .question = r.question }, cancel);
                defer a.free(output.text);
                if (cancel.isRequested()) return error.Canceled;
                try j.put(a, &value, "path", j.str(r.path));
                try j.put(a, &value, "mime", j.str(picture.format.mime()));
                try j.put(a, &value, "width", try j.number(picture.width));
                try j.put(a, &value, "height", try j.number(picture.height));
                try j.put(a, &value, "description", j.str(output.text));
                try j.put(a, &value, "usage_scope", j.str("auxiliary_image"));
                const usage_json = try std.json.Stringify.valueAlloc(a, output.usage, .{});
                defer a.free(usage_json);
                const usage = try std.json.parseFromSliceLeaky(std.json.Value, a, usage_json, .{ .allocate = .alloc_always });
                try j.put(a, &value, "usage", usage);
                return .{ .text = try j.encode(a, value) };
            },
            .read_file => |r| {
                // truncated 时 next_offset 指向下一段起点，模型可据此继续分页读取。
                const result = try self.root.readExternalGuarded(a, r.path, r.offset, r.limit orelse 32768, self.textReadGuard());
                try j.put(a, &value, "path", j.str(r.path));
                try j.put(a, &value, "offset", try j.number(result.offset));
                try j.put(a, &value, "bytes_read", try j.number(result.data.len));
                try j.put(a, &value, "next_offset", try j.number(result.offset + result.data.len));
                try j.put(a, &value, "file_bytes", try j.number(result.total_bytes));
                try j.put(a, &value, "truncated", .{ .bool = result.truncated });
                try j.put(a, &value, "content", j.str(result.data));
                return .{ .text = try j.encode(a, value), .truncated = result.truncated, .file_stats = .{ .read = @import("../util/line_stats.zig").count(result.data), .partial = result.offset != 0 or result.truncated } };
            },

            .edit_file => |edit| {
                const edit_limit: ?usize = null;
                const before = try self.root.readBinaryGuarded(a, edit.path, edit_limit, self.textReadGuard());
                defer a.free(before);
                try fs.validateText(before);
                const applied = try text_edit.applyObserved(a, before, edit.edits, edit_limit);
                const after = applied.bytes;
                defer a.free(after);
                try fs.validateText(after);
                try j.put(a, &value, "path", j.str(edit.path));
                try j.put(a, &value, "written_bytes", try j.number(after.len));
                const encoded = try j.encode(a, value);
                errdefer a.free(encoded);
                if (cancel.isRequested()) return error.Canceled;
                // A best-effort stale check, not a cross-process CAS.
                const current = try self.root.readBinaryGuarded(a, edit.path, edit_limit, self.textReadGuard());
                defer a.free(current);
                if (!std.mem.eql(u8, before, current)) return error.FileChanged;
                if (cancel.isRequested()) return error.Canceled;
                const changes = try self.root.writeObserved(edit.path, after, true);
                return .{ .text = encoded, .file_stats = .{ .changes = changes orelse applied.changes } };
            },

            .write_file => |w| {
                // 成功结果先分配，避免文件已提交后却因 JSON 分配失败而报告普通 OOM。
                try j.put(a, &value, "path", j.str(w.path));
                try j.put(a, &value, "written_bytes", try j.number(w.content.len));
                const encoded = try j.encode(a, value);
                errdefer a.free(encoded);
                // 原子写入以及“已存在需 overwrite=true”的检查由 Root.write 负责。
                const changes = try self.root.writeObserved(w.path, w.content, w.overwrite);
                return .{ .text = encoded, .file_stats = .{ .changes = changes } };
            },

            .bash => |b| {
                if (b.background) {
                    // Background start: keep the same risk classification and
                    // approval path (prepare already attached them). Only the
                    // bounded startup wait uses the timeout; the Manager owns
                    // the running service without a Tools/Runtime deadline.
                    const service = self.background orelse return error.BackgroundDisabled;
                    if (self.parentChannelActive()) return error.BackgroundDisabled;
                    try service.checkReady();
                    const startup_ms = b.timeout_ms orelse self.config.limits.command_timeout_ms;
                    if (cancel.isRequested()) return error.Canceled;
                    // Start and handoff happen inside this call; the mutation
                    // gate is released when it returns, never held across the
                    // service lifetime.
                    const started = try service.start(a, .{
                        .command = b.command,
                        .startup_timeout_ms = startup_ms,
                        .term_grace_ms = cfg.Policy.cleanup_grace_ms,
                        .cleanup_timeout_ms = cfg.Policy.cleanup_timeout_ms,
                    }, cancel);
                    return mapBackgroundResult(started, true);
                }
                // 超时、取消与输出上限都交给 process.run；返回的标记用于区分失败原因。
                const result = try process.run(a, self.root.io, self.root.path, b.command, self.environment, .{
                    .timeout_ms = b.timeout_ms orelse self.config.limits.command_timeout_ms,
                    .output_bytes = null,
                    .term_grace_ms = cfg.Policy.cleanup_grace_ms,
                    .cleanup_timeout_ms = cfg.Policy.cleanup_timeout_ms,
                    .cwd_dir = self.root.dir,
                }, cancel);
                // Preserve cleanup failure even if later JSON allocation would
                // fail. Runtime must stop accepting work in this case.
                if (result.cleanup_failed) return .{
                    .text = "Command cleanup could not be confirmed. A child may remain alive or unreaped; side effects are not rolled back. Stop and inspect before continuing.",
                    .is_error = true,
                    .cleanup_failed = true,
                    .canceled = result.canceled,
                    .truncated = true,
                };

                // 输出以 UTF-8 转义表示：非法字节写成 \xHH，字面反斜杠加倍，模型可无歧义地解读。
                try j.put(a, &value, "output_encoding", j.str("utf8; unsafe bytes escaped as \\xHH; literal backslashes doubled"));
                try j.put(a, &value, "stdout", j.str(result.stdout));
                try j.put(a, &value, "stderr", j.str(result.stderr));
                try j.put(a, &value, "stdout_bytes", try j.number(result.stdout_bytes));
                try j.put(a, &value, "stderr_bytes", try j.number(result.stderr_bytes));
                try j.put(a, &value, "truncated", .{ .bool = result.truncated });
                try j.put(a, &value, "timed_out", .{ .bool = result.timed_out });
                try j.put(a, &value, "canceled", .{ .bool = result.canceled });
                try j.put(a, &value, "cleanup_failed", .{ .bool = result.cleanup_failed });

                // 失败判定：超时、取消、清理失败、非零退出码或被信号终止，都视为错误。
                var failed = result.timed_out or result.canceled or result.cleanup_failed;
                if (result.term) |term| switch (term) {
                    .exited => |code| {
                        try j.put(a, &value, "exit_code", try j.number(code));
                        failed = failed or code != 0;
                    },
                    .signal => |signal| {
                        try j.put(a, &value, "signal", try j.number(@backingInt(signal)));
                        failed = true;
                    },
                    else => failed = true,
                } else failed = true;

                return .{
                    .text = try j.encode(a, value),
                    .is_error = failed,
                    .canceled = result.canceled,
                    .truncated = result.truncated,
                    .cleanup_failed = result.cleanup_failed,
                };
            },

            // topic/content 在 parse 中已校验存在，这里的 .? 不会失败。
            .memory => |m| switch (m.action) {
                .list => {
                    const limit: usize = if (m.limit) |page_limit| @intCast(page_limit) else mem.default_list_limit;
                    const page = try self.memory.listPage(a, @intCast(m.offset), limit);
                    const core = try self.memory.coreSnapshot(a);
                    const snapshot = if (core.len == 0) blk: {
                        a.free(core);
                        break :blk page.text;
                    } else if (page.text.len == 0) blk: {
                        a.free(page.text);
                        break :blk core;
                    } else blk: {
                        const joined = std.fmt.allocPrint(a, "{s}\n\n{s}", .{ core, page.text }) catch |err| {
                            a.free(core);
                            a.free(page.text);
                            return err;
                        };
                        a.free(core);
                        a.free(page.text);
                        break :blk joined;
                    };
                    try j.put(a, &value, "current_snapshot", j.str(snapshot));
                    try j.put(a, &value, "total", try j.number(page.total));
                    try j.put(a, &value, "offset", try j.number(page.offset));
                    try j.put(a, &value, "count", try j.number(page.count));
                    if (page.offset + page.count < page.total)
                        try j.put(a, &value, "next_offset", try j.number(page.offset + page.count))
                    else
                        try j.put(a, &value, "next_offset", .null);
                },

                .read => {
                    const entry = try self.memory.read(a, m.topic.?);
                    try j.put(a, &value, "topic", j.str(m.topic.?));
                    try j.put(a, &value, "content", j.str(entry.content));
                    try j.put(a, &value, "version", j.str(entry.version));
                },

                .write => {
                    // 版本仅取决于新内容；包括最终 JSON 在内的返回内存必须先于 CAS 提交。
                    const next_version = try mem.version(a, m.content.?);
                    defer a.free(next_version);
                    try j.put(a, &value, "topic", j.str(m.topic.?));
                    try j.put(a, &value, "operation", j.str(if (m.expected_version == null) "created" else "updated"));
                    try j.put(a, &value, "version", j.str(next_version));
                    const encoded = try j.encode(a, value);
                    errdefer a.free(encoded);
                    // expected_version 为空表示创建；非空则必须与当前版本一致。
                    const entry = try self.memory.write(a, m.topic.?, m.content.?, m.expected_version);
                    a.free(entry.content);
                    a.free(entry.version);
                    return .{ .text = encoded };
                },

                .delete => {
                    // 删除同样先构造结果；成功 unlink 后不再进行可能失败的分配。
                    try j.put(a, &value, "topic", j.str(m.topic.?));
                    try j.put(a, &value, "operation", j.str("deleted"));
                    const encoded = try j.encode(a, value);
                    errdefer a.free(encoded);
                    try self.memory.delete(m.topic.?, m.expected_version.?);
                    return .{ .text = encoded };
                },
            },

            .subagent => |request| {
                const service = self.subagent orelse return error.SubagentDisabled;
                // Readiness is checked here only: prepare stays pure.
                try service.checkReady();
                if (cancel.isRequested()) return error.Canceled;
                return mapServiceResult(try service.run(a, request, cancel));
            },

            .get_subagent_result => |query| {
                const service = self.subagent orelse return error.SubagentDisabled;
                try service.checkReady();
                if (cancel.isRequested()) return error.Canceled;
                return mapServiceResult(try service.get(a, query, cancel));
            },

            .send_subagent_message => |message| {
                const service = self.subagent orelse return error.SubagentDisabled;
                try service.checkReady();
                if (cancel.isRequested()) return error.Canceled;
                return mapServiceResult(try service.send(a, message, cancel));
            },

            .cancel_subagent => |request| {
                const service = self.subagent orelse return error.SubagentDisabled;
                if (cancel.isRequested()) return error.Canceled;
                return mapServiceResult(try service.cancel(a, request, cancel));
            },

            .background => |query| {
                const service = self.background orelse return error.BackgroundDisabled;
                if (self.parentChannelActive()) return error.BackgroundDisabled;
                // The ordinary-execution poison check above already returns
                // error.CleanupFailed when the service is unhealthy, matching
                // the documented fail-stop rule.
                if (cancel.isRequested()) return error.Canceled;
                const result = try service.control(a, query, cancel);
                // Stopping one service never cancels the current Q&A: the
                // service token is not propagated as parent Execution.canceled.
                return mapBackgroundResult(result, query.action != .stop);
            },

            .message_parent => |message| {
                const channel = self.parent_channel orelse return error.SubagentMessageDisabled;
                if (cancel.isRequested()) return error.Canceled;
                return mapServiceResult(try channel.message(a, message, cancel));
            },
        }

        return .{ .text = try j.encode(a, value) };
    }

    /// The App owns encoding: Result.text is already the bounded tool-result
    /// JSON (status incl. paused/canceled, report, usage, messages, ...). Pass it
    /// through verbatim: re-encoding would double-wrap the JSON, drop statuses
    /// Tools does not know, and add an allocation that could mask a cleanup
    /// failure. Runtime's fitResult still bounds bytes. All communication and
    /// delegation results stay single-layer JSON and never become automatic
    /// Memory evidence. A child's canceled terminal state does not set the
    /// parent Execution.canceled flag; that flag only follows the Result's
    /// explicit parent-call cancellation.
    fn mapServiceResult(result: subagent.Result) Execution {
        const cleanup = result.cleanup_failed;
        return .{
            .text = result.text,
            .is_error = result.is_error or result.canceled or cleanup,
            .canceled = result.canceled and !cleanup,
            .truncated = result.truncated,
            .cleanup_failed = cleanup,
            .memory_evidence = false,
        };
    }

    /// Same verbatim contract for the instance background service: `text` is
    /// already the bounded single-layer JSON result and is never re-encoded, so
    /// a cleanup failure cannot be masked by a later allocation failure.
    /// Cleanup failure outranks cancellation. A management `stop` reports the
    /// stopped service's cancellation but must not mark the current Q&A call
    /// canceled; only start/list/status/logs interrupted by the parent token do.
    fn mapBackgroundResult(result: background.Result, propagate_canceled: bool) Execution {
        const cleanup = result.cleanup_failed;
        const canceled = propagate_canceled and result.canceled and !cleanup;
        return .{
            .text = result.text,
            .is_error = result.is_error or canceled or cleanup,
            .canceled = canceled,
            .truncated = result.truncated,
            .cleanup_failed = cleanup,
            .memory_evidence = false,
        };
    }
};

/// Small explicit environment, not a sandbox. HOME may still contain credentials
/// readable by the same OS user. Always remove the configured credential name,
/// even if it collides with an otherwise allowed variable.
/// 为 bash 构造最小环境：只保留白名单变量，并移除 secret_name 指定的凭据变量。
pub fn commandEnvironment(a: std.mem.Allocator, source: *const std.process.Environ.Map, secret_name: []const u8) !std.process.Environ.Map {
    return commandEnvironmentMany(a, source, &.{secret_name});
}

fn secretEnvironmentName(key: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, key, name)) return true;
    return false;
}

/// Filter every configured provider's credential source BEFORE copying values.
/// Inactive providers must not leak a key even when its name is whitelisted.
pub fn commandEnvironmentMany(a: std.mem.Allocator, source: *const std.process.Environ.Map, secret_names: []const []const u8) !std.process.Environ.Map {
    var result = std.process.Environ.Map.init(a);
    errdefer result.deinit();

    // 白名单：只传递运行常见命令所需的变量，其余（如 API key）一律丢弃。
    const allowed = [_][]const u8{ "PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR", "TZ" };
    for (allowed) |key| {
        if (secretEnvironmentName(key, secret_names)) continue;
        if (source.get(key)) |value| try result.put(key, value);
    }

    // PATH 缺失时补默认值；但若 PATH 本身就是凭据名，则不补，避免把它当成可用的 PATH。
    if (result.get("PATH") == null and !secretEnvironmentName("PATH", secret_names)) try result.put("PATH", "/usr/bin:/bin");
    return result;
}

// schema 顺序是对外契约，且每个 parameters_json 都必须是合法 JSON 对象。

// 参数必须严格校验（路径越界、版本缺失、未知字段等），保留动作类型。

// 即使凭据名与白名单中的变量重名，也必须从命令环境中移除，其他白名单变量保留。

// Records service calls without any process, filesystem or network work.
