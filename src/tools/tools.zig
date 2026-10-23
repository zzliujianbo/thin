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
const memory_queue = @import("memory_queue.zig");
const process = @import("../platform/process.zig");
const j = @import("../util/json.zig");
const runtime = @import("../core/runtime.zig");
const command_risk = @import("command_risk.zig");
const decision = @import("../core/decision.zig");
const image = @import("../core/image.zig");
const image_file = @import("image_file.zig");

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
        .description = "Run bash in the startup project; cwd changes do not persist. With decision review disabled, ordinary commands run without approval prompts; classified high-risk commands require explicit approval each time. Denial means no execution. timeout_ms follows host limits; built-in default is 5 minutes. stdout/stderr retain bounded head/tail, not full logs.",
        .parameters_json =
        \\{"type":"object","properties":{"command":{"type":"string"},"timeout_ms":{"type":"integer","minimum":1}},"required":["command"],"additionalProperties":false}
        ,
    },
    .{
        .name = "memory",
        .description = "Store explicit durable project facts or reusable preferences, not transcripts or temporary progress. list returns core/index; read returns content and version. Writes/deletes remain subject to host validation and limits. Create without expected_version; update/delete use read's version as expected_version. On conflict, reread; never overwrite blindly. topic core is startup core memory; other topics are ASCII slugs. status returns automatic-job IDs/states without source text. retry uses a failed/uncertain job ID as topic and always needs explicit human approval because a previous inference may already have been billed; Auto memory must be On.",
        .parameters_json =
        \\{"type":"object","properties":{"action":{"type":"string","enum":["list","read","write","delete","status","retry"]},"topic":{"type":"string"},"content":{"type":"string"},"expected_version":{"type":["string","null"]}},"required":["action"],"additionalProperties":false}
        ,
    },
};

// The configured reviewer, not the legacy shell classifier, owns the extra
// command-confirmation decision. These static variants add no prompt allocation
// and preserve tool IDs, order and parameter schemas.
const decision_bash_description = "Run bash in the startup project; cwd changes do not persist. The configured reviewer's ask=true requires approval for this call; ask=false removes the extra command-approval prompt. The reviewer also chooses the command deadline. Unavailable or invalid review pauses without executing. Denial means no execution. Hard validation, task deadlines, cancellation and output limits apply. stdout/stderr retain bounded head/tail, not full logs.";
const decision_memory_description = "Store explicit durable project facts or reusable preferences, not transcripts or temporary progress. list returns core/index; read returns content and version. Only write candidates are reviewed for durable value; skipped writes make no change, and a useful candidate is not authorization. Writes/deletes remain subject to host validation and limits. Create without expected_version; update/delete use read's version as expected_version. On conflict, reread; never overwrite blindly. topic core is startup core memory; other topics are ASCII slugs. status returns automatic-job IDs/states without source text. retry uses a failed/uncertain job ID as topic and always needs explicit human approval because a previous inference may already have been billed; Auto memory must be On.";
const reviewed_schemas = blk: {
    var result = schemas;
    result[2].description = decision_bash_description;
    result[3].description = decision_memory_description;
    break :blk result;
};
fn schemasForDecision(enabled: bool) []const p.ToolSchema {
    return if (enabled) &reviewed_schemas else &schemas;
}

const image_schema: p.ToolSchema = .{
    .name = "read_image",
    .description = "Inspect a local PNG/JPEG/GIF/WebP inside the startup project using the independent image service. Returns bounded text and auxiliary usage only, never image bytes. No URLs. Maximum file size 4 MiB and dimensions 8192. question is optional.",
    .parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string"},"question":{"type":"string","minLength":1,"maxLength":4096}},"required":["path"],"additionalProperties":false}
    ,
};
const image_schemas = schemas ++ [_]p.ToolSchema{image_schema};
const reviewed_image_schemas = reviewed_schemas ++ [_]p.ToolSchema{image_schema};
fn schemasForServices(review: bool, enabled: bool) []const p.ToolSchema {
    if (!enabled) return schemasForDecision(review);
    return if (review) &reviewed_image_schemas else &image_schemas;
}
pub const ReadImage = struct { path: []const u8, question: []const u8 = image.default_question };
fn validateReadImage(r: ReadImage) !void {
    try validatePath(r.path);
    if (std.ascii.startsWithIgnoreCase(r.path, "http://") or std.ascii.startsWithIgnoreCase(r.path, "https://")) return error.InvalidImagePath;
    if (r.question.len == 0 or r.question.len > image.max_question_bytes or !std.unicode.utf8ValidateSlice(r.question) or std.mem.indexOfScalar(u8, r.question, 0) != null) return error.InvalidImageQuestion;
}

/// read_file 的解析结果；offset 为字节偏移，limit 为空时使用配置的 read_bytes。
pub const Read = struct { path: []const u8, offset: u64 = 0, limit: ?u32 = null };
/// write_file 的解析结果；覆盖已有文件必须显式设置 overwrite。
pub const Write = struct { path: []const u8, content: []const u8, overwrite: bool = false };
/// bash 的解析结果；timeout_ms 为空时使用配置的默认超时。
pub const Bash = struct { command: []const u8, timeout_ms: ?u32 = null };

/// memory 工具的解析结果；topic 为 core 或 ASCII slug，list 时不得携带其他字段。
pub const Memory = struct {
    /// 操作类型：list/read/write/delete/status/retry；retry 的 topic 是 job ID。
    action: enum { list, read, write, delete, status, retry },
    /// 目标主题；list 时必须为空。
    topic: ?[]const u8 = null,
    /// 写入内容，仅 write 使用。
    content: ?[]const u8 = null,
    /// 乐观并发版本（内容哈希）：write 更新与 delete 必须提供，create 必须为空。
    expected_version: ?[]const u8 = null,
};

/// 已解析且通过基本校验的工具动作；内部的切片指向解析时的 arena。
pub const Action = union(enum) {
    read_file: Read,
    read_image: ReadImage,
    write_file: Write,
    bash: Bash,
    memory: Memory,

    /// 生成展示给用户的授权描述；写入 memory 时附带完整内容，便于用户审阅后再批准。
    pub fn description(self: Action, a: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .read_file => |r| try std.fmt.allocPrint(a, "Read {s}", .{r.path}),
            .read_image => |r| try std.fmt.allocPrint(a, "Inspect image {s}", .{r.path[0..@min(r.path.len, 4096)]}),
            .write_file => |w| try std.fmt.allocPrint(a, "{s} {s} ({d} bytes)", .{
                if (w.overwrite) "Write/replace" else "Create", w.path, w.content.len,
            }),
            .bash => |b| try std.fmt.allocPrint(a, "Run bash: {s}", .{b.command}),
            // create 与 update 的区别仅在于 expected_version 是否为空。
            .memory => |m| if (m.action == .write)
                try std.fmt.allocPrint(a, "Memory {s}: {s} ({d} bytes)\n{s}", .{ if (m.expected_version == null) "create" else "update", m.topic.?, m.content.?.len, m.content.? })
            else
                try std.fmt.allocPrint(a, "Memory {s}: {s}", .{ @tagName(m.action), m.topic orelse "index" }),
        };
    }
};

/// Parse and validate before requesting authorization. a is a short-lived arena.
/// 在请求授权前解析并校验参数；a 是短生命周期 arena，返回值中的字符串都归它所有。
pub fn parse(a: std.mem.Allocator, name: []const u8, arguments: []const u8, limits: cfg.Limits) !Action {
    // 先限制原始参数大小，防止超大 JSON 占用内存。
    if (arguments.len > limits.max_response_bytes) return error.ArgumentsTooLarge;
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
        const limit = args.limit orelse limits.read_bytes;
        if (limit == 0 or limit > limits.read_bytes) return error.InvalidReadLimit;
        return .{ .read_file = args };
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
        if (args.command.len == 0 or args.command.len > 32768 or std.mem.findScalar(u8, args.command, 0) != null)
            return error.InvalidCommand;
        const timeout = args.timeout_ms orelse limits.command_timeout_ms;
        if (timeout == 0 or timeout > limits.command_max_timeout_ms) return error.InvalidCommandTimeout;
        return .{ .bash = args };
    }

    if (std.mem.eql(u8, name, "memory")) {
        const args = try std.json.parseFromSliceLeaky(Memory, a, arguments, opts);
        // list 不接受 topic/content/版本号，保持调用形状严格。
        if (args.action == .list or args.action == .status) {
            if (args.topic != null or args.content != null or args.expected_version != null)
                return error.InvalidMemoryArguments;
        } else if (args.action == .retry) {
            const id = args.topic orelse return error.MissingMemoryTopic;
            if (id.len != 64 or args.content != null or args.expected_version != null) return error.InvalidMemoryArguments;
            for (id) |byte| if (!(byte >= '0' and byte <= '9') and !(byte >= 'a' and byte <= 'f')) return error.InvalidMemoryArguments;
        } else {
            // 非 list 操作都必须带合法 topic（core 或 ASCII slug）。
            const topic = args.topic orelse return error.MissingMemoryTopic;
            mem.validTopic(topic) catch return error.InvalidMemoryTopic;
            // 写入：按 core 或分片分别限制大小，并校验 UTF-8 与 NUL。
            if (args.action == .write) {
                const content = args.content orelse return error.MissingMemoryContent;
                const max = if (std.mem.eql(u8, topic, "core")) limits.core_bytes else limits.shard_bytes;
                if (content.len > max) return error.MemoryTooLarge;
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
    /// 项目内 memory 存储（.thin/mem）。
    memory: *mem.Store,
    /// 运行时配置，包含各类上限与超时。
    config: *const cfg.Config,
    /// 传给 bash 的环境变量（已经过 commandEnvironment 过滤）。
    environment: *const std.process.Environ.Map,
    /// 由应用层传入的认证文件 realPath；与 Root.path 使用同一真实路径空间，
    /// 即使启动目录是 HOME 或 HOME 本身是别名，也不能通过模型文件工具泄露凭证。
    auth_path: ?[]const u8 = null,
    /// Explicit opt-in; no service means no fifth schema and no file access.
    image: ?image.Service = null,

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
            else => return,
        };
        if (action == .read_file) {
            try validateReadPath(path);
            const limit = action.read_file.limit orelse self.config.limits.read_bytes;
            if (limit == 0 or limit > self.config.limits.read_bytes) return error.InvalidReadLimit;
            // Text policy is applied to actual descriptors below, not a resolve
            // against root.path, which can name a different parent after rename.
            return;
        }
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
                if (action == .write_file and std.mem.eql(u8, part, "mem")) return error.UseMemoryTool;
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
                    if (action == .write_file) return error.ProtectedSessionFile;
                    break;
                }
                break;
            }
        }
        // Writing the .thin parent itself must not replace the Memory namespace.
        if (in_thin and action == .write_file) return error.UseMemoryTool;
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
        const protected_fd = fs.openPath(protected.fd, protected.name) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer fs.closeFd(protected_fd);
        return fs.sameObject(opened, protected_fd);
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
        return .{ .context = self, .schemas = schemasForServices(self.config.decisionActive(), self.image != null), .prepare_fn = prepare, .execute_fn = executePrepared };
    }

    /// 解析并做路径校验，生成待授权的 Prepared；此阶段不产生任何副作用。
    fn prepare(context_: *anyopaque, a: std.mem.Allocator, call: p.ToolCall) !runtime.Prepared {
        const self: *Tools = @ptrCast(@alignCast(context_));
        const action = try a.create(Action);
        action.* = try parse(a, call.name, call.arguments, self.config.limits);
        try self.checkImageAction(action.*);
        try self.checkFileAction(a, action.*);
        if (action.* == .read_file) {
            self.root.probeExternalRead(action.read_file.path, self.textReadGuard()) catch |err| switch (err) {
                // Another call in this batch may create the file or its parent.
                // Execution resolves afresh and guards the descriptor it reads.
                error.FileNotFound => {},
                else => return err,
            };
        }
        // 危险 bash 在授权前打标。Runtime 看到 explicit_denial 后逐次询问。
        var description = try action.description(a);
        const denial: ?[]const u8 = if (action.* == .bash) blk: {
            const finding = command_risk.classify(action.bash.command) orelse break :blk null;
            description = try std.fmt.allocPrint(a, "DANGEROUS bash ({s}). Explicit approval is required each time; y runs it once, n denies it.\n{s}", .{ finding.label, description });
            break :blk try std.fmt.allocPrint(a, "Dangerous bash command was not executed ({s}). High-risk bash needs an explicit user allow each time.", .{finding.label});
        } else if (action.* == .memory and action.memory.action == .retry)
            "Memory retry was not executed. Explicit approval is required: an uncertain inference may already have been billed; retry can incur another charge."
        else
            null;
        const review: ?decision.Input = switch (action.*) {
            .bash => |b| .{ .command = .{
                .command = b.command,
                .proposed_timeout_ms = b.timeout_ms,
                .max_timeout_ms = self.config.limits.command_max_timeout_ms,
                .risk = if (command_risk.classify(b.command)) |finding| finding.label else null,
            } },
            .memory => |m| if (m.action == .write) .{ .memory_write = .{
                .topic = m.topic.?,
                .content = m.content.?,
                .expected_version = m.expected_version,
            } } else null,
            else => null,
        };
        return .{ .payload = action, .description = description, .explicit_denial = denial, .decision_input = review };
    }

    /// 从 prepare 生成的 payload 取回 Action 并执行；payload 指向同一个 arena 中的 Action。
    fn executePrepared(context_: *anyopaque, a: std.mem.Allocator, prepared: runtime.Prepared, cancel: *const p.Cancellation) !Execution {
        const self: *Tools = @ptrCast(@alignCast(context_));
        const action: *const Action = @ptrCast(@alignCast(prepared.payload));
        return self.executeWithTimeout(a, action.*, prepared.command_timeout, cancel);
    }

    /// Explicit approval is a Runtime responsibility. Never call this for an
    /// operation requiring approval before it is granted. This function does no terminal I/O.
    /// 按 Action 执行具体副作用，并把结果编码为 JSON 文本；本函数不做任何终端输入输出。
    pub fn execute(self: *Tools, a: std.mem.Allocator, action: Action, cancel: *const p.Cancellation) !Execution {
        return self.executeWithTimeout(a, action, null, cancel);
    }

    fn executeWithTimeout(self: *Tools, a: std.mem.Allocator, action: Action, timeout: ?decision.Timeout, cancel: *const p.Cancellation) !Execution {
        // Readiness/poison and argument guards are pure and precede all I/O.
        try self.checkImageAction(action);
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
                const result = try self.root.readExternalGuarded(a, r.path, r.offset, r.limit orelse self.config.limits.read_bytes, self.textReadGuard());
                try j.put(a, &value, "path", j.str(r.path));
                try j.put(a, &value, "offset", try j.number(result.offset));
                try j.put(a, &value, "bytes_read", try j.number(result.data.len));
                try j.put(a, &value, "next_offset", try j.number(result.offset + result.data.len));
                try j.put(a, &value, "file_bytes", try j.number(result.total_bytes));
                try j.put(a, &value, "truncated", .{ .bool = result.truncated });
                try j.put(a, &value, "content", j.str(result.data));
                return .{ .text = try j.encode(a, value), .truncated = result.truncated, .file_stats = .{ .read = @import("../util/line_stats.zig").count(result.data), .partial = result.offset != 0 or result.truncated } };
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
                // 超时、取消与输出上限都交给 process.run；返回的标记用于区分失败原因。
                const limit: ?u32 = if (timeout) |policy| switch (policy) {
                    .none => null,
                    .milliseconds => |ms| if (ms == 0 or ms > self.config.limits.command_max_timeout_ms) return error.InvalidTimeout else ms,
                } else b.timeout_ms orelse self.config.limits.command_timeout_ms;
                const result = try process.run(a, self.root.io, self.root.path, b.command, self.environment, .{
                    .timeout_ms = limit,
                    .output_bytes = self.config.limits.output_bytes,
                    .term_grace_ms = self.config.limits.cleanup_grace_ms,
                    .cleanup_timeout_ms = self.config.limits.cleanup_timeout_ms,
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
                    try j.put(a, &value, "current_snapshot", j.str(try self.memory.snapshot(a)));
                },

                .status => {
                    var queue = memory_queue.Queue.init(self.root);
                    try j.put(a, &value, "jobs", j.str(try queue.status(a)));
                },

                .retry => {
                    if (!self.config.memory.auto) return error.MemoryAutoDisabled;
                    try j.put(a, &value, "job", j.str(m.topic.?));
                    try j.put(a, &value, "operation", j.str("queued"));
                    const encoded = try j.encode(a, value);
                    errdefer a.free(encoded);
                    var queue = memory_queue.Queue.init(self.root);
                    try queue.retry(a, m.topic.?);
                    return .{ .text = encoded };
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
        }

        return .{ .text = try j.encode(a, value) };
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
test "tool schemas have stable order and valid JSON" {
    try std.testing.expectEqualStrings("read_file", schemas[0].name);
    try std.testing.expectEqualStrings("memory", schemas[3].name);

    for ([_]bool{ false, true }) |review| for (schemasForDecision(review), schemas) |schema, original| {
        try std.testing.expectEqualStrings(original.name, schema.name);
        try std.testing.expectEqualStrings(original.parameters_json, schema.parameters_json);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema.parameters_json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
    };
}

test "tool descriptions distinguish configured decision review from legacy approval" {
    const plain = schemasForDecision(false);
    const reviewed = schemasForDecision(true);
    try std.testing.expect(std.mem.indexOf(u8, plain[2].description, "decision review disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain[2].description, "high-risk commands require explicit approval") != null);
    try std.testing.expect(std.mem.indexOf(u8, reviewed[2].description, "ask=true requires approval for this call") != null);
    try std.testing.expect(std.mem.indexOf(u8, reviewed[2].description, "ask=false removes the extra command-approval prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, reviewed[2].description, "Unavailable or invalid review pauses without executing") != null);
    try std.testing.expect(std.mem.indexOf(u8, reviewed[3].description, "a useful candidate is not authorization") != null);
    for ([_]usize{ 0, 1 }) |i| try std.testing.expectEqualStrings(plain[i].description, reviewed[i].description);
    for ([_]bool{ false, true }) |review| {
        const selected = schemasForDecision(review);
        try std.testing.expect(std.mem.indexOf(u8, selected[0].description, "next_offset as the next call's offset") != null);
        try std.testing.expect(std.mem.indexOf(u8, selected[3].description, "read's version as expected_version") != null);
    }
}

// 参数必须严格校验（路径越界、版本缺失、未知字段等），保留动作类型。
test "tool arguments remain strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const read = try parse(a, "read_file", "{\"path\":\"a.zig\"}", .{});
    try std.testing.expect(read == .read_file);
    const write = try parse(a, "write_file", "{\"path\":\"a.zig\",\"content\":\"hello\"}", .{});
    try std.testing.expect(write == .write_file);
    const external = try parse(a, "read_file", "{\"path\":\"../outside.txt\"}", .{});
    try std.testing.expectEqualStrings("../outside.txt", external.read_file.path);
    try std.testing.expectError(error.PathEscape, parse(a, "write_file", "{\"path\":\"../outside.txt\",\"content\":\"x\"}", .{}));
    try std.testing.expectError(error.InvalidReadLimit, parse(a, "read_file", "{\"path\":\"a\",\"limit\":99999999}", .{}));
    try std.testing.expectError(error.MissingMemoryVersion, parse(a, "memory", "{\"action\":\"delete\",\"topic\":\"core\"}", .{}));
    try std.testing.expectError(error.UnknownField, parse(a, "bash", "{\"command\":\"true\",\"trust\":true}", .{}));
}

// 即使凭据名与白名单中的变量重名，也必须从命令环境中移除，其他白名单变量保留。
test "command environment excludes fake credentials even under a normally allowed name" {
    var source = std.process.Environ.Map.init(std.testing.allocator);
    defer source.deinit();
    try source.put("PATH", "fake-secret");
    try source.put("OTHER_API_KEY", "another-fake-secret");
    try source.put("LANG", "C.UTF-8");

    var filtered = try commandEnvironment(std.testing.allocator, &source, "PATH");
    defer filtered.deinit();
    try std.testing.expect(filtered.get("PATH") == null);
    try std.testing.expect(filtered.get("OTHER_API_KEY") == null);
    try std.testing.expectEqualStrings("C.UTF-8", filtered.get("LANG").?);
}

test "project settings exact aliases protected at prepare and direct execute" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, io, buffer[0..n]);
    defer root.deinit();
    const config: cfg.Config = .{ .provider = .{ .base_url = "http://127.0.0.1" }, .model = .{ .name = "fake", .context_tokens = 10000 } };
    var tools: Tools = .{ .root = &root, .memory = undefined, .config = &config, .environment = undefined };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const absolute = try std.fs.path.join(a, &.{ root.path, ".thin/./settings.json" });
    var cancel: p.Cancellation = .{};
    for ([_][]const u8{ settings.relative_path, "./.thin//./settings.json", ".thin/./settings.json/.", absolute }) |path| {
        try std.testing.expectError(error.ProtectedSettingsFile, tools.checkFileAction(a, .{ .read_file = .{ .path = path } }));
        try std.testing.expectError(error.ProtectedSettingsFile, tools.execute(a, .{ .read_file = .{ .path = path } }, &cancel));
        try std.testing.expectError(error.ProtectedSettingsFile, tools.execute(a, .{ .write_file = .{ .path = path, .content = "x" } }, &cancel));
        const read_args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\"}}", .{path});
        const write_args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\",\"content\":\"x\"}}", .{path});
        try std.testing.expectError(error.ProtectedSettingsFile, Tools.prepare(&tools, a, .{ .id = "r", .name = "read_file", .arguments = read_args }));
        try std.testing.expectError(error.ProtectedSettingsFile, Tools.prepare(&tools, a, .{ .id = "w", .name = "write_file", .arguments = write_args }));
    }
    for ([_][]const u8{ ".thin/settings.jsonfoo", ".thin/sub/settings.json", "settings.json", ".thin/settings.json/child" }) |path| {
        try tools.checkFileAction(a, .{ .read_file = .{ .path = path } });
    }
    for ([_][]const u8{ ".thin/sessions/x", ".thin/logs/x" }) |path| {
        try tools.checkFileAction(a, .{ .read_file = .{ .path = path } });
        try std.testing.expectError(error.ProtectedSessionFile, tools.checkFileAction(a, .{ .write_file = .{ .path = path, .content = "x", .overwrite = true } }));
    }
}

test "dangerous bash is marked for explicit approval and ordinary bash is not" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, io, buffer[0..n]);
    defer root.deinit();
    const config: cfg.Config = .{ .provider = .{ .base_url = "http://127.0.0.1" }, .model = .{ .name = "fake", .context_tokens = 10000 } };
    var tools: Tools = .{ .root = &root, .memory = undefined, .config = &config, .environment = undefined };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dangerous = try Tools.prepare(&tools, a, .{ .id = "d", .name = "bash", .arguments = "{\"command\":\"rm -rf build\"}" });
    try std.testing.expect(dangerous.explicit_denial != null);
    try std.testing.expect(std.mem.indexOf(u8, dangerous.explicit_denial.?, "recursive delete") != null);
    try std.testing.expect(std.mem.indexOf(u8, dangerous.explicit_denial.?, "explicit user allow each time") != null);
    try std.testing.expect(std.mem.indexOf(u8, dangerous.description, "DANGEROUS bash") != null);

    const safe = try Tools.prepare(&tools, a, .{ .id = "s", .name = "bash", .arguments = "{\"command\":\"printf ok\"}" });
    try std.testing.expect(safe.explicit_denial == null);
    try std.testing.expect(std.mem.indexOf(u8, safe.description, "DANGEROUS") == null);
}

test "image tool strict arguments schemas guards and bounded text output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ false, true }) |review| {
        const off = schemasForServices(review, false);
        const on = schemasForServices(review, true);
        try std.testing.expectEqual(@as(usize, 4), off.len);
        try std.testing.expectEqual(@as(usize, 5), on.len);
        for (off, on[0..4]) |old, new| {
            try std.testing.expectEqualStrings(old.name, new.name);
            try std.testing.expectEqualStrings(old.description, new.description);
            try std.testing.expectEqualStrings(old.parameters_json, new.parameters_json);
        }
        try std.testing.expectEqualStrings("read_image", on[4].name);
    }
    const parsed = try parse(a, "read_image", "{\"path\":\"fixture.bin\"}", .{});
    try std.testing.expectEqualStrings(image.default_question, parsed.read_image.question);
    try std.testing.expectError(error.UnknownField, parse(a, "read_image", "{\"path\":\"x\",\"url\":\"x\"}", .{}));
    try std.testing.expectError(error.InvalidImagePath, parse(a, "read_image", "{\"path\":\"HTTPS://host/x\"}", .{}));
    try std.testing.expectError(error.PathEscape, parse(a, "read_image", "{\"path\":\"../x\"}", .{}));
    try std.testing.expectError(error.InvalidImageQuestion, validateReadImage(.{ .path = "x", .question = "\xff" }));
    try std.testing.expectError(error.InvalidImageQuestion, validateReadImage(.{ .path = "x", .question = "\x00" }));
    try std.testing.expectError(error.InvalidImageQuestion, parse(a, "read_image", "{\"path\":\"x\",\"question\":\"\"}", .{}));
    const Fake = struct {
        calls: usize = 0,
        poisoned: bool = false,
        fail: bool = false,
        fn check(raw: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.poisoned) return error.CleanupFailed;
        }
        fn inspect(raw: *anyopaque, alloc: std.mem.Allocator, input: image.Input, _: *const p.Cancellation) !image.Output {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqualStrings(image_file.test_gif, input.image.data);
            try std.testing.expectEqualStrings(image.default_question, input.question);
            try std.testing.expectEqual(image.Format.gif, input.image.format);
            if (self.fail) return error.InvalidImageResponse;
            return .{ .text = try alloc.dupe(u8, "small fixture"), .usage = .{ .input_tokens = 7, .output_tokens = 2 } };
        }
    };
    var fake: Fake = .{};
    const service: image.Service = .{ .context = &fake, .inspect_fn = Fake.inspect, .check_fn = Fake.check };
    const config: cfg.Config = .{ .provider = .{ .base_url = "http://127.0.0.1" }, .model = .{ .name = "fake", .context_tokens = 10000 } };
    // Undefined root proves pure guards never dereference a filesystem object.
    var tools: Tools = .{ .root = undefined, .memory = undefined, .config = &config, .environment = undefined };
    var cancel: p.Cancellation = .{};
    try std.testing.expectError(error.ImageDisabled, tools.execute(a, parsed, &cancel));
    try std.testing.expectError(error.ImageDisabled, Tools.prepare(&tools, a, .{ .id = "i", .name = "read_image", .arguments = "{\"path\":\"x\"}" }));
    tools.image = service;
    cancel.cancel();
    try std.testing.expect((try tools.execute(a, parsed, &cancel)).canceled);
    fake.poisoned = true;
    try std.testing.expectError(error.CleanupFailed, tools.execute(a, parsed, &cancel));
    try std.testing.expectError(error.CleanupFailed, Tools.prepare(&tools, a, .{ .id = "i", .name = "read_image", .arguments = "{\"path\":\"x\"}" }));
    fake.poisoned = false;
    cancel = .{};
    try std.testing.expectError(error.InvalidImageQuestion, tools.execute(a, .{ .read_image = .{ .path = "x", .question = "" } }, &cancel));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
    defer root.deinit();
    tools.root = &root;
    // prepare on a missing file succeeds without reading it or calling inspect.
    _ = try Tools.prepare(&tools, a, .{ .id = "i", .name = "read_image", .arguments = "{\"path\":\"fixture.bin\"}" });
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fixture.bin", .data = image_file.test_gif });
    const result = try tools.execute(a, parsed, &cancel);
    const json = try std.json.parseFromSliceLeaky(std.json.Value, a, result.text, .{});
    try std.testing.expectEqualStrings("small fixture", json.object.get("description").?.string);
    try std.testing.expectEqualStrings("image/gif", json.object.get("mime").?.string);
    try std.testing.expectEqual(@as(i64, 7), json.object.get("usage").?.object.get("input_tokens").?.integer);
    try std.testing.expect(json.object.get("data") == null and json.object.get("base64") == null);
    fake.fail = true;
    try std.testing.expectError(error.InvalidImageResponse, tools.execute(a, parsed, &cancel));
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    tools.auth_path = try std.fs.path.join(a, &.{ root.path, "fixture.bin" });
    try std.testing.expectError(error.ProtectedAuthFile, tools.execute(a, parsed, &cancel));
    try std.testing.expectError(error.ProtectedSettingsFile, tools.execute(a, .{ .read_image = .{ .path = ".thin/settings.json" } }, &cancel));
}

test {
    _ = @import("command_risk.zig");
}
