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
const knowledge_store = @import("knowledge_store.zig");
const process = @import("../platform/process.zig");
const j = @import("../util/json.zig");
const runtime = @import("../core/runtime.zig");
const command_risk = @import("command_risk.zig");
const image = @import("../core/image.zig");
const image_file = @import("image_file.zig");
const text_edit = @import("text_edit.zig");
const background = @import("../core/background.zig");

/// Foreground bash description. The background variant appends its own sentence
/// so a child Tools without a service never advertises background capability.
const bash_description = "Run bash in the startup project; cwd changes do not persist. Use command, or commands (1-20) for independent concurrent jobs; batches share cwd/env, return results in input order, and reject high-risk commands. High-risk single commands need explicit approval. timeout_ms defaults to 5 minutes per command; item timeout_ms overrides. Single-command output is complete; batch output is bounded and marks truncation.";

/// 暴露给模型的工具 schema 列表；顺序是对外契约（测试依赖 read_file 在 0、memory 在 3）。
pub const schemas = [_]p.ToolSchema{
    .{
        .name = "read_file",
        .description = "Read a UTF-8 file. Relative paths start at the startup project; absolute and ../ paths may read outside it; credentials and symlinks are denied. offset is a zero-based BYTE offset; limit is a BYTE count. When truncated, continue with next_offset.",
        .parameters_json =
        \\{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1}},"required":["path"],"additionalProperties":false}
        ,
    },
    .{
        .name = "write_file",
        .description = "Atomically write a UTF-8 file inside the startup project or under /tmp. Parent directory must exist; overwrite=true is required to replace. Read before editing.",
        .parameters_json =
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"overwrite":{"type":"boolean"}},"required":["path","content"],"additionalProperties":false}
        ,
    },
    .{
        .name = "bash",
        .description = bash_description,
        .parameters_json = bash_parameters_json,
    },
    .{
        .name = "memory",
        .description = "Store explicit durable project facts or reusable preferences, not transcripts or temporary progress. list returns one page of the core/index; use offset and limit to page. read returns content. write creates or replaces the topic; delete removes it. Writes/deletes remain subject to host validation and limits. topic names match the `.md` files listed by list; the suffix is optional on input and included in results. core is startup core memory; other topics are ASCII slugs.",
        .parameters_json =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["list","read","write","delete"]},"topic":{"type":"string"},"content":{"type":"string"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1}},"required":["action"],"additionalProperties":false}
        ,
    },
};

/// Background variants only appear when the host supplied a background service
/// to a root Tools. They state that the bounded timeout covers startup only,
/// so the command timeout is not mistaken for the lifetime of a handed-off service.
const background_bash_description = bash_description ++ " background=true starts a managed service and bounds only startup, not how long the service keeps running; use the background tool for logs/status/stop. Batch commands are foreground only.";

const bash_parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string","minLength":1},"commands":{"type":"array","minItems":1,"maxItems":20,"items":{"type":"object","properties":{"command":{"type":"string","minLength":1},"timeout_ms":{"type":"integer","minimum":1}},"required":["command"],"additionalProperties":false}},"timeout_ms":{"type":"integer","minimum":1}},"anyOf":[{"required":["command"]},{"required":["commands"]}],"additionalProperties":false}
;
const bash_background_parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string","minLength":1},"commands":{"type":"array","minItems":1,"maxItems":20,"items":{"type":"object","properties":{"command":{"type":"string","minLength":1},"timeout_ms":{"type":"integer","minimum":1}},"required":["command"],"additionalProperties":false}},"timeout_ms":{"type":"integer","minimum":1},"background":{"type":"boolean"}},"anyOf":[{"required":["command"]},{"required":["commands"]}],"additionalProperties":false}
;

/// One management tool, appended after every other root tool. It exists only
/// when a background service is available.
const background_schema: p.ToolSchema = .{
    .name = "background",
    .description = "Manage background commands started with bash background=true: list (default 20), status, logs (absolute byte offsets and limit), or stop one service. Results are returned only here; completion does not add a conversation turn.",
    .parameters_json =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["list","status","logs","stop"]},"id":{"type":"string","minLength":1,"maxLength":64},"after":{"type":"integer","minimum":0},"stdout_offset":{"type":"integer","minimum":0},"stderr_offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1}},"required":["action"],"additionalProperties":false}
    ,
};
const image_schema: p.ToolSchema = .{
    .name = "read_image",
    .description = "Inspect a local PNG/JPEG/GIF/WebP inside the startup project using the independent image service. Returns bounded text and auxiliary usage only, never image bytes. No URLs. Maximum file size 4 MiB and dimensions 8192. question is optional.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"question":{"type":"string","minLength":1,"maxLength":4096}},"required":["path"],"additionalProperties":false}
    ,
};
/// Largest schema set: read/write/bash/memory + image + background management
/// and edit_file.
const max_schemas = 7;
const edit_schema: p.ToolSchema = .{
    .name = "edit_file",
    .description = "Atomically replace exact unique text in an existing project file or under /tmp. All edits match the original text, must be non-overlapping, and are applied together. Read the file first.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"edits":{"type":"array","minItems":1,"items":{"type":"object","properties":{"old_text":{"type":"string","minLength":1},"new_text":{"type":"string"}},"required":["old_text","new_text"],"additionalProperties":false}}},"required":["path","edits"],"additionalProperties":false}
    ,
};
const schema_choices = 2;

fn buildSchemas(comptime image_on: bool, comptime memory_on: bool, comptime background_on: bool) [max_schemas]p.ToolSchema {
    var result: [max_schemas]p.ToolSchema = undefined;
    var count: usize = 0;
    for (&schemas, 0..) |schema, i| {
        // Preserve read/write/bash/memory order; only memory is conditional.
        if (i == 3 and !memory_on) continue;
        if (i == 2 and background_on) {
            // Same name and index, but the parameters expose the optional
            // background dimension and the description explains startup-only
            // timeouts. A Tools without a service keeps the old schema bytes.
            result[count] = .{
                .name = schema.name,
                .description = background_bash_description,
                .parameters_json = bash_background_parameters_json,
            };
        } else result[count] = schema;
        count += 1;
    }
    if (image_on) {
        result[count] = image_schema;
        count += 1;
    }
    // Appended last so every previous tool keeps its index.
    if (background_on) {
        result[count] = background_schema;
        count += 1;
    }
    result[count] = edit_schema;
    return result;
}

// Static table of the small feature matrix. Slices point into read-only data, so
// a rebind never invalidates a previously handed-out schema slice.
const schema_table = blk: {
    @setEvalBranchQuota(160000);
    var table: [schema_choices][schema_choices][schema_choices][max_schemas]p.ToolSchema = undefined;
    for (0..schema_choices) |background_on| for (0..schema_choices) |image_on| for (0..schema_choices) |memory_on| {
        table[background_on][image_on][memory_on] = buildSchemas(image_on == 1, memory_on == 1, background_on == 1);
    };
    break :blk table;
};

fn schemaCount(image_on: bool, memory_on: bool, background_on: bool) usize {
    return 5 + @as(usize, @intFromBool(image_on)) + @as(usize, @intFromBool(background_on)) - @as(usize, @intFromBool(!memory_on));
}

fn schemasWith(image_on: bool, memory_on: bool, background_on: bool) []const p.ToolSchema {
    const set: *const [max_schemas]p.ToolSchema = &schema_table[@intFromBool(background_on)][@intFromBool(image_on)][@intFromBool(memory_on)];
    return set[0..schemaCount(image_on, memory_on, background_on)];
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
const max_batch_commands = 20;
const batch_concurrency = 5;
const batch_command_output_bytes = 10 * 1024;
const batch_total_output_bytes = 200 * 1024;

pub const BashCommand = struct { command: []const u8, timeout_ms: ?u32 = null };
/// bash 的解析结果。单命令用 command；批量用 commands。二者互斥，background
/// 只适用于单命令，批量命令始终前台执行并 join。
pub const Bash = struct {
    command: []const u8 = "",
    commands: []const BashCommand = &.{},
    timeout_ms: ?u32 = null,
    background: bool = false,
};

/// memory 工具的解析结果；topic 为 core 或 ASCII slug，list 时不得携带其他字段。
pub const Memory = struct {
    /// 操作类型：list/read/write/delete。
    action: enum { list, read, write, delete },
    /// 目标主题；list 时必须为空。
    topic: ?[]const u8 = null,
    /// 写入内容，仅 write 使用。
    content: ?[]const u8 = null,
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

    /// 生成展示给用户的授权描述；写入 memory 时附带完整内容，便于用户审阅后再批准。
    pub fn description(self: Action, a: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .read_file => |r| try std.fmt.allocPrint(a, "Read {s}", .{r.path}),
            .read_image => |r| try std.fmt.allocPrint(a, "Inspect image {s}", .{r.path[0..@min(r.path.len, 4096)]}),
            .write_file => |w| try std.fmt.allocPrint(a, "{s} {s} ({d} bytes)", .{
                if (w.overwrite) "Write/replace" else "Create", w.path, w.content.len,
            }),
            .edit_file => |e| try std.fmt.allocPrint(a, "Edit {s} ({d} edits)", .{ e.path, e.edits.len }),
            .bash => |b| if (b.commands.len != 0)
                try std.fmt.allocPrint(a, "Run bash batch ({d} commands)", .{b.commands.len})
            else if (b.background)
                try std.fmt.allocPrint(a, "$ {s}\n(background service)", .{b.command})
            else
                try std.fmt.allocPrint(a, "$ {s}", .{b.command}),
            .background => |q| if (q.id) |id|
                try std.fmt.allocPrint(a, "Background {s} {s}", .{ q.action.name(), id })
            else
                try std.fmt.allocPrint(a, "Background {s}", .{q.action.name()}),
            .memory => |m| if (m.action == .write)
                try std.fmt.allocPrint(a, "Memory write: {s} ({d} bytes)\n{s}", .{ m.topic.?, m.content.?.len, m.content.? })
            else
                try std.fmt.allocPrint(a, "Memory {s}: {s}", .{ @tagName(m.action), m.topic orelse "index" }),
        };
    }
};

/// Parse and validate before requesting authorization. a is a short-lived arena.
/// 在请求授权前解析并校验参数；a 是短生命周期 arena，返回值中的字符串都归它所有。
pub fn parse(a: std.mem.Allocator, name: []const u8, arguments: []const u8, limits: cfg.Limits) !Action {
    // 严格模式：拒绝未知字段（如伪造的 trust），并让字符串复制进 arena，不借用输入缓冲。
    const opts: std.json.ParseOptions = .{ .allocate = .alloc_always, .ignore_unknown_fields = false };
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
        const BashArgs = struct {
            command: ?[]const u8 = null,
            commands: ?[]const BashCommand = null,
            timeout_ms: ?u32 = null,
            background: bool = false,
        };
        const args = try std.json.parseFromSliceLeaky(BashArgs, a, arguments, opts);
        if (args.commands) |commands| {
            if (args.command != null or args.background or commands.len == 0 or commands.len > max_batch_commands)
                return error.InvalidCommand;
            for (commands) |item| {
                if (item.command.len == 0 or std.mem.findScalar(u8, item.command, 0) != null) return error.InvalidCommand;
                if (item.timeout_ms != null and item.timeout_ms.? == 0) return error.InvalidCommandTimeout;
            }
            const timeout = args.timeout_ms orelse limits.command_timeout_ms;
            if (timeout == 0) return error.InvalidCommandTimeout;
            return .{ .bash = .{ .commands = commands, .timeout_ms = args.timeout_ms } };
        }
        const command = args.command orelse return error.InvalidCommand;
        // 命令必须非空且不允许 NUL；超时必须在 (0, 配置上限] 之内。
        if (command.len == 0 or std.mem.findScalar(u8, command, 0) != null) return error.InvalidCommand;
        const timeout = args.timeout_ms orelse limits.command_timeout_ms;
        if (timeout == 0) return error.InvalidCommandTimeout;
        return .{ .bash = .{ .command = command, .timeout_ms = args.timeout_ms, .background = args.background } };
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

    if (std.mem.eql(u8, name, "memory")) {
        var args = try std.json.parseFromSliceLeaky(Memory, a, arguments, opts);
        // list 不接受 topic/content/版本号，保持调用形状严格。
        if (args.action == .list) {
            if (args.topic != null or args.content != null)
                return error.InvalidMemoryArguments;
            if (args.limit) |limit| if (limit == 0 or limit > mem.max_list_limit) return error.InvalidMemoryArguments;
        } else {
            if (args.offset != 0 or args.limit != null) return error.InvalidMemoryArguments;
            // 非 list 操作都必须带合法 topic（core 或 ASCII slug）。
            // list 显示的是文件名（`topic.md`），输入允许带同样的 `.md` 后缀。
            const raw_topic = args.topic orelse return error.MissingMemoryTopic;
            const topic = if (std.mem.endsWith(u8, raw_topic, ".md")) raw_topic[0 .. raw_topic.len - 3] else raw_topic;
            mem.validTopic(topic) catch return error.InvalidMemoryTopic;
            args.topic = topic;
            // 写入：按 core 或分片分别限制大小，并校验 UTF-8 与 NUL。
            if (args.action == .write) {
                const content = args.content orelse return error.MissingMemoryContent;
                if (!std.unicode.utf8ValidateSlice(content) or std.mem.findScalar(u8, content, 0) != null)
                    return error.InvalidText;
            } else if (args.content != null) return error.InvalidMemoryArguments;
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
    /// Optional instance-owned background registry. When present, Tools
    /// exposes bash background=true and the management tool.
    background: ?background.Service = null,
    /// False hides the memory schema and rejects forged memory calls (child Tools).
    allow_memory: bool = true,
    fn backgroundActive(self: *Tools) bool {
        return self.background != null;
    }

    fn isBackgroundManaged(name: []const u8) bool {
        return std.mem.eql(u8, name, "background");
    }

    fn checkAvailableActions(self: *Tools, action: Action) !void {
        switch (action) {
            .bash => |b| {
                if (b.timeout_ms != null and b.timeout_ms.? == 0) return error.InvalidCommandTimeout;
                if (b.commands.len != 0) {
                    if (b.background or b.commands.len > max_batch_commands) return error.InvalidCommand;
                    for (b.commands) |item| {
                        if (item.command.len == 0 or std.mem.findScalar(u8, item.command, 0) != null or
                            !std.unicode.utf8ValidateSlice(item.command)) return error.InvalidCommand;
                        if (item.timeout_ms != null and item.timeout_ms.? == 0) return error.InvalidCommandTimeout;
                        if (command_risk.classify(item.command) != null) return error.HighRiskBatch;
                    }
                } else if (b.command.len == 0 or std.mem.findScalar(u8, b.command, 0) != null or
                    !std.unicode.utf8ValidateSlice(b.command))
                {
                    return error.InvalidCommand;
                }
                if (b.background and !self.backgroundActive()) return error.BackgroundDisabled;
            },
            .background => if (!self.backgroundActive()) return error.BackgroundDisabled,
            .memory => if (!self.allow_memory) return error.MemoryDisabled,
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

    const tmp_write_prefix = "/tmp/";
    fn isTmpWritePath(path: []const u8) bool {
        return std.mem.startsWith(u8, path, tmp_write_prefix) and path.len > tmp_write_prefix.len;
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
        const inside_root = std.mem.eql(u8, absolute, self.root.path) or
            (std.mem.startsWith(u8, absolute, self.root.path) and absolute.len > self.root.path.len and absolute[self.root.path.len] == '/');
        if (is_write and isTmpWritePath(path) and !inside_root) {
            // /tmp is the explicit external write sink. Rooted operations still
            // reject '..', NUL, symlinks and non-regular targets.
            try validatePath(path);
            if (self.auth_path) |protected| if (std.mem.eql(u8, absolute, protected)) return error.ProtectedAuthFile;
            return;
        }
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
            .schemas = schemasWith(self.image != null, self.allow_memory, self.backgroundActive()),
            .prepare_fn = prepare,
            .execute_fn = executePrepared,
            .preview_write_fn = previewWrite,
            .end_task_fn = endTask,
        };
    }

    /// Instance-owned background health check at normal root end. Background
    /// services survive the root task and are only checked for cleanup health.
    fn endTask(context_: *anyopaque, cancel: *const p.Cancellation) !void {
        const self: *Tools = @ptrCast(@alignCast(context_));
        _ = cancel;
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

    const BatchJob = struct {
        command: []const u8,
        timeout_ms: u32,
        output_bytes: usize,
        cancel: *const p.Cancellation,
        root: *fs.Root,
        environment: *const std.process.Environ.Map,
        arena: std.heap.ArenaAllocator,
        result: ?process.Result = null,
        failure: ?anyerror = null,
        skipped: bool = false,
        duration_ms: u64 = 0,

        fn init(root: *fs.Root, environment: *const std.process.Environ.Map, command: []const u8, timeout_ms: u32, output_bytes: usize, cancel: *const p.Cancellation) BatchJob {
            return .{
                .command = command,
                .timeout_ms = timeout_ms,
                .output_bytes = output_bytes,
                .cancel = cancel,
                .root = root,
                .environment = environment,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            };
        }

        fn run(self: *BatchJob) void {
            if (self.cancel.isRequested()) {
                self.skipped = true;
                return;
            }
            const began = std.Io.Clock.awake.now(self.root.io);
            self.result = process.run(self.arena.allocator(), self.root.io, self.root.path, self.command, self.environment, .{
                .timeout_ms = self.timeout_ms,
                .output_bytes = self.output_bytes,
                .term_grace_ms = cfg.Policy.cleanup_grace_ms,
                .cleanup_timeout_ms = cfg.Policy.cleanup_timeout_ms,
                .cwd_dir = self.root.dir,
            }, self.cancel) catch |err| {
                self.failure = err;
                return;
            };
            self.duration_ms = @intCast(@max(0, began.untilNow(self.root.io, .awake).toMilliseconds()));
        }

        fn deinit(self: *BatchJob) void {
            self.arena.deinit();
        }
    };

    fn executeBashBatch(self: *Tools, a: std.mem.Allocator, b: Bash, cancel: *const p.Cancellation) !Execution {
        var results = j.array(a);
        var failed = false;
        var timed_out = false;
        var canceled = false;
        var truncated = false;
        var cleanup_failed = false;
        var next: usize = 0;
        const output_bytes = @max(1, @min(batch_command_output_bytes, batch_total_output_bytes / b.commands.len));
        while (next < b.commands.len) {
            var jobs: [batch_concurrency]BatchJob = undefined;
            const count = @min(batch_concurrency, b.commands.len - next);
            for (0..count) |i| {
                const item = b.commands[next + i];
                const timeout = item.timeout_ms orelse b.timeout_ms orelse self.config.limits.command_timeout_ms;
                jobs[i] = BatchJob.init(self.root, self.environment, item.command, timeout, output_bytes, cancel);
            }
            defer for (jobs[0..count]) |*job| job.deinit();
            var group: std.Io.Group = .init;
            for (jobs[0..count]) |*job| {
                group.concurrent(self.root.io, BatchJob.run, .{job}) catch |err| {
                    group.cancel(self.root.io);
                    return err;
                };
            }
            group.await(self.root.io) catch |err| {
                if (err != error.Canceled) return err;
            };
            for (jobs[0..count], 0..) |*job, i| {
                const index = next + i + 1;
                var item = j.object(a);
                try j.put(a, &item, "index", try j.number(index));
                try j.put(a, &item, "command", j.str(job.command));
                if (job.skipped) {
                    try j.put(a, &item, "canceled", .{ .bool = true });
                    try j.put(a, &item, "failed", .{ .bool = true });
                    try j.put(a, &item, "error", j.str("not started: batch canceled"));
                    failed = true;
                    canceled = true;
                } else if (job.failure) |err| {
                    try j.put(a, &item, "error", j.str(@errorName(err)));
                    try j.put(a, &item, "failed", .{ .bool = true });
                    if (err == error.Canceled) {
                        try j.put(a, &item, "canceled", .{ .bool = true });
                        canceled = true;
                    }
                    if (err == error.CleanupFailed) {
                        try j.put(a, &item, "cleanup_failed", .{ .bool = true });
                        cleanup_failed = true;
                    }
                    failed = true;
                } else if (job.result) |result| {
                    try j.put(a, &item, "stdout", j.str(try a.dupe(u8, result.stdout)));
                    try j.put(a, &item, "stderr", j.str(try a.dupe(u8, result.stderr)));
                    try j.put(a, &item, "stdout_bytes", try j.number(result.stdout_bytes));
                    try j.put(a, &item, "stderr_bytes", try j.number(result.stderr_bytes));
                    try j.put(a, &item, "truncated", .{ .bool = result.truncated });
                    try j.put(a, &item, "timed_out", .{ .bool = result.timed_out });
                    try j.put(a, &item, "canceled", .{ .bool = result.canceled });
                    try j.put(a, &item, "cleanup_failed", .{ .bool = result.cleanup_failed });
                    try j.put(a, &item, "duration_ms", try j.number(job.duration_ms));
                    var command_failed = result.timed_out or result.canceled or result.cleanup_failed;
                    if (result.term) |term| switch (term) {
                        .exited => |code| {
                            try j.put(a, &item, "exit_code", try j.number(code));
                            command_failed = command_failed or code != 0;
                        },
                        .signal => |signal| {
                            try j.put(a, &item, "signal", try j.number(@backingInt(signal)));
                            command_failed = true;
                        },
                        else => command_failed = true,
                    } else command_failed = true;
                    try j.put(a, &item, "failed", .{ .bool = command_failed });
                    failed = failed or command_failed;
                    timed_out = timed_out or result.timed_out;
                    canceled = canceled or result.canceled;
                    truncated = truncated or result.truncated;
                    cleanup_failed = cleanup_failed or result.cleanup_failed;
                } else {
                    try j.put(a, &item, "canceled", .{ .bool = true });
                    try j.put(a, &item, "failed", .{ .bool = true });
                    try j.put(a, &item, "error", j.str("not started: batch canceled"));
                    failed = true;
                    canceled = true;
                }
                try j.append(&results, item);
            }
            next += count;
            if (canceled or cleanup_failed) break;
        }
        while (next < b.commands.len) : (next += 1) {
            var item = j.object(a);
            try j.put(a, &item, "index", try j.number(next + 1));
            try j.put(a, &item, "command", j.str(b.commands[next].command));
            try j.put(a, &item, "canceled", .{ .bool = true });
            try j.put(a, &item, "failed", .{ .bool = true });
            try j.put(a, &item, "error", j.str("not started: batch canceled"));
            try j.append(&results, item);
            failed = true;
            canceled = true;
        }
        var value = j.object(a);
        try j.put(a, &value, "output_encoding", j.str("utf8; unsafe bytes escaped as \\xHH; literal backslashes doubled"));
        try j.put(a, &value, "commands", results);
        try j.put(a, &value, "failed", .{ .bool = failed });
        try j.put(a, &value, "timed_out", .{ .bool = timed_out });
        try j.put(a, &value, "canceled", .{ .bool = canceled });
        try j.put(a, &value, "truncated", .{ .bool = truncated });
        try j.put(a, &value, "cleanup_failed", .{ .bool = cleanup_failed });
        return .{
            .text = try j.encode(a, value),
            .is_error = failed or canceled or cleanup_failed,
            .canceled = canceled and !cleanup_failed,
            .truncated = truncated,
            .cleanup_failed = cleanup_failed,
            .memory_evidence = false,
        };
    }

    /// 解析并做路径校验，生成待授权的 Prepared；此阶段不产生任何副作用。
    fn prepare(context_: *anyopaque, a: std.mem.Allocator, call: p.ToolCall) !runtime.Prepared {
        const self: *Tools = @ptrCast(@alignCast(context_));
        // Names the model was never offered must not become executable actions.
        // Reject before parsing or allocating anything.
        if (!self.allow_memory and std.mem.eql(u8, call.name, "memory")) return error.MemoryDisabled;
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
        // 审批弹框只展示命令；风险标签只留在给模型的拒绝文案里。
        const description = try action.description(a);
        const risk = if (action.* == .bash) command_risk.classify(action.bash.command) else null;
        const denial: ?[]const u8 = if (risk) |finding|
            try std.fmt.allocPrint(a, "Dangerous bash command was not executed ({s}). High-risk bash needs an explicit user allow each time.", .{finding.label})
        else
            null;
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
        // Display-only summary subject; the Runtime never parses tool arguments
        // to discover it and never treats it as a validated path.
        const edited_path: ?[]const u8 = switch (action.*) {
            .write_file => |w| w.path,
            .edit_file => |e| e.path,
            else => null,
        };
        return .{ .payload = action, .description = description, .explicit_denial = denial, .edited_path = edited_path, .display = display };
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
                var tmp_root: ?fs.Root = if (isTmpWritePath(edit.path)) try fs.Root.open(a, self.root.io, "/tmp") else null;
                defer if (tmp_root) |*root| root.deinit();
                const file_root = if (tmp_root) |*root| root else self.root;
                const file_path = if (tmp_root != null) edit.path[tmp_write_prefix.len..] else edit.path;
                const before = try file_root.readBinaryGuarded(a, file_path, edit_limit, self.textReadGuard());
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
                const current = try file_root.readBinaryGuarded(a, file_path, edit_limit, self.textReadGuard());
                defer a.free(current);
                if (!std.mem.eql(u8, before, current)) return error.FileChanged;
                if (cancel.isRequested()) return error.Canceled;
                const changes = try file_root.writeObserved(file_path, after, true);
                return .{ .text = encoded, .file_stats = .{ .changes = changes orelse applied.changes } };
            },

            .write_file => |w| {
                // 成功结果先分配，避免文件已提交后却因 JSON 分配失败而报告普通 OOM。
                try j.put(a, &value, "path", j.str(w.path));
                try j.put(a, &value, "written_bytes", try j.number(w.content.len));
                const encoded = try j.encode(a, value);
                errdefer a.free(encoded);
                var tmp_root: ?fs.Root = if (isTmpWritePath(w.path)) try fs.Root.open(a, self.root.io, "/tmp") else null;
                defer if (tmp_root) |*root| root.deinit();
                const file_root = if (tmp_root) |*root| root else self.root;
                const file_path = if (tmp_root != null) w.path[tmp_write_prefix.len..] else w.path;
                // 原子写入以及“已存在需 overwrite=true”的检查由 Root.write 负责。
                const changes = try file_root.writeObserved(file_path, w.content, w.overwrite);
                return .{ .text = encoded, .file_stats = .{ .changes = changes } };
            },

            .bash => |b| {
                if (b.commands.len != 0) return try self.executeBashBatch(a, b, cancel);
                if (b.background) {
                    // Background start: keep the same risk classification and
                    // approval path (prepare already attached them). Only the
                    // bounded startup wait uses the timeout; the Manager owns
                    // the running service without a Tools/Runtime deadline.
                    const service = self.background orelse return error.BackgroundDisabled;
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
                    var repository = knowledge_store.Repository.init(self.memory);
                    const content = try repository.readContent(a, m.topic.?);
                    defer a.free(content);
                    const topic_file = try std.fmt.allocPrint(a, "{s}.md", .{m.topic.?});
                    defer a.free(topic_file);
                    try j.put(a, &value, "topic", j.str(topic_file));
                    try j.put(a, &value, "content", j.str(content));
                    const encoded = try j.encode(a, value);
                    return .{ .text = encoded };
                },

                .write => {
                    const topic_file = try std.fmt.allocPrint(a, "{s}.md", .{m.topic.?});
                    defer a.free(topic_file);
                    try j.put(a, &value, "topic", j.str(topic_file));
                    try j.put(a, &value, "operation", j.str("written"));
                    const encoded = try j.encode(a, value);
                    errdefer a.free(encoded);
                    const entry = try self.memory.replace(a, m.topic.?, m.content.?);
                    a.free(entry.content);
                    return .{ .text = encoded };
                },

                .delete => {
                    // 删除同样先构造结果；成功 unlink 后不再进行可能失败的分配。
                    const topic_file = try std.fmt.allocPrint(a, "{s}.md", .{m.topic.?});
                    defer a.free(topic_file);
                    try j.put(a, &value, "topic", j.str(topic_file));
                    try j.put(a, &value, "operation", j.str("deleted"));
                    const encoded = try j.encode(a, value);
                    errdefer a.free(encoded);
                    try self.memory.remove(m.topic.?);
                    return .{ .text = encoded };
                },
            },

            .background => |query| {
                const service = self.background orelse return error.BackgroundDisabled;
                // The ordinary-execution poison check above already returns
                // error.CleanupFailed when the service is unhealthy, matching
                // the documented fail-stop rule.
                if (cancel.isRequested()) return error.Canceled;
                const result = try service.control(a, query, cancel);
                // Stopping one service never cancels the current Q&A: the
                // service token is not propagated as parent Execution.canceled.
                return mapBackgroundResult(result, query.action != .stop);
            },
        }

        return .{ .text = try j.encode(a, value) };
    }

    /// Background results are already bounded single-layer JSON and are never
    /// re-encoded, so a cleanup failure cannot be masked by a later allocation
    /// failure. Cleanup failure outranks cancellation. A management `stop`
    /// reports the stopped service's cancellation but must not mark the current
    /// Q&A call canceled; only start/list/status/logs interrupted by the parent
    /// token do.
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
