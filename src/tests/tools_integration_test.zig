//! 工具层集成测试：验证路径约束、memory 命名空间保护、审批前的校验，以及文件/命令工具结果的 UTF-8 与续读偏移。

const std = @import("std");
const p = @import("../core/protocol.zig");
const cfg = @import("../core/config.zig");
const fs = @import("../platform/filesystem.zig");
const mem = @import("../tools/memory.zig");
const t = @import("../tools/tools.zig");
const j = @import("../util/json.zig");

/// 测试用配置：provider 地址为不可达的占位主机，防止误连真实服务。
const configuration = cfg.Config{
    .limits = .{ .low_price_input = false },
    .provider = .{ .base_url = "http://unused.invalid", .api_key_env = "FAKE_KEY" },
    .model = .{ .name = "fake", .context_tokens = 32768 },
};

test "executor selects decision-aware descriptions without changing tool parameters" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buffer);
    var root = try fs.Root.open(a, std.testing.io, buffer[0..n]);
    defer root.deinit();
    var store = mem.Store.init(&root, .{});
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    var config = configuration;
    var tools = t.Tools{ .root = &root, .memory = &store, .config = &config, .environment = &environment };
    const plain = tools.executor().schemas;
    try std.testing.expect(std.mem.indexOf(u8, plain[2].description, "decision review disabled") != null);
    for ([_]cfg.DecisionConfig{
        .{ .model = "judge/fake" },
        .{ .model = "judge/jev-fixture", .backend = .systemone },
    }) |decision| {
        config.decision = decision;
        const reviewed = tools.executor().schemas;
        try std.testing.expectEqual(plain.len, reviewed.len);
        for (plain, reviewed) |old, current| {
            try std.testing.expectEqualStrings(old.name, current.name);
            try std.testing.expectEqualStrings(old.parameters_json, current.parameters_json);
        }
        try std.testing.expect(std.mem.indexOf(u8, reviewed[2].description, "ask=false removes") != null);
        try std.testing.expect(std.mem.indexOf(u8, reviewed[3].description, "write candidates are reviewed") != null);
    }
    config.decision = null;
    try std.testing.expectEqualStrings(plain[2].description, tools.executor().schemas[2].description);
}

test "file observations reflect actual returned ranges and pre-write snapshot changes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(a, io, buffer[0..n]);
    defer root.deinit();
    var store = mem.Store.init(&root, .{});
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    var tools = t.Tools{ .root = &root, .memory = &store, .config = &configuration, .environment = &environment };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var cancel = p.Cancellation{};
    const Stats = @import("../util/line_stats.zig");
    const initial = "a\nb\nc\nd\ne\n";
    const create = try tools.execute(temp, .{ .write_file = .{ .path = "lines.txt", .content = initial } }, &cancel);
    try std.testing.expectEqualDeep(Stats.Changes{ .added = 5 }, create.file_stats.?.changes.?);
    const read = try tools.execute(temp, .{ .read_file = .{ .path = "lines.txt" } }, &cancel);
    try std.testing.expectEqual(@as(?u64, 5), read.file_stats.?.read);
    try std.testing.expect(!read.file_stats.?.partial);
    const range = try tools.execute(temp, .{ .read_file = .{ .path = "lines.txt", .offset = 1, .limit = 2 } }, &cancel);
    try std.testing.expectEqual(@as(?u64, 2), range.file_stats.?.read);
    try std.testing.expect(range.file_stats.?.partial); // "\nb": two returned line fragments.
    const update = try tools.execute(temp, .{ .write_file = .{ .path = "lines.txt", .content = "a\nB\nx\nc\ne\n", .overwrite = true } }, &cancel);
    try std.testing.expectEqualDeep(Stats.Changes{ .modified = 1, .added = 1, .removed = 1 }, update.file_stats.?.changes.?);
    const same = try tools.execute(temp, .{ .write_file = .{ .path = "lines.txt", .content = "a\nB\nx\nc\ne\n", .overwrite = true } }, &cancel);
    try std.testing.expectEqualDeep(Stats.Changes{}, same.file_stats.?.changes.?);
    try std.testing.expectError(error.PathAlreadyExists, tools.execute(temp, .{ .write_file = .{ .path = "lines.txt", .content = "not committed" } }, &cancel));
    cancel.cancel();
    const canceled = try tools.execute(temp, .{ .write_file = .{ .path = "lines.txt", .content = "not committed", .overwrite = true } }, &cancel);
    try std.testing.expect(canceled.canceled and canceled.file_stats == null);
    const contents = try root.read(temp, "lines.txt", 0, 100);
    try std.testing.expectEqualStrings("a\nB\nx\nc\ne\n", contents.data);

    // Observation OOM is non-authoritative and occurs before the actual commit.
    for ([_]usize{ 1, 4 }) |fail_index| {
        try root.write("lines.txt", "a\nB\nx\nc\ne\n", true);
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        // parent(0), snapshot(1), before/after lines(2/3), LCS table(4).
        root.allocator = failing.allocator();
        defer root.allocator = a;
        const unavailable = try root.writeObserved("lines.txt", "new\n", true);
        root.allocator = a;
        try std.testing.expect(unavailable == null);
        const committed = try root.read(temp, "lines.txt", 0, 100);
        try std.testing.expectEqualStrings("new\n", committed.data);
    }
}

// 验证：写入 .thin 或 memory 目录被拒绝（UseMemoryTool），越界路径被拒绝（OutsideRoot），合法 memory 写入只生成待审批描述且不落盘。
test "tools validate containment and Memory namespace before approval" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(a, io, buffer[0..n]);
    defer root.deinit();
    var store = mem.Store.init(&root, .{});
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    var tools = t.Tools{ .root = &root, .memory = &store, .config = &configuration, .environment = &environment };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    const executor = tools.executor();

    var cancel = p.Cancellation{};
    const memory_path = try std.fs.path.join(temp, &.{ root.path, ".thin/mem/core.md" });
    // Both entrypoints protect Memory aliases; direct calls cannot bypass CAS.
    for ([_][]const u8{ ".thin", ".thin/mem/core.md", ".thin//./mem/a.md", memory_path }) |path| {
        const args = try std.fmt.allocPrint(temp, "{{\"path\":\"{s}\",\"content\":\"x\"}}", .{path});
        try std.testing.expectError(error.UseMemoryTool, executor.prepare_fn(executor.context, temp, .{ .id = "c", .name = "write_file", .arguments = args }));
        try std.testing.expectError(error.UseMemoryTool, tools.execute(temp, .{ .write_file = .{ .path = path, .content = "x" } }, &cancel));
    }

    // 新旧会话目录允许只读；prepare 不创建文件，写入在两个入口仍受保护。
    const session_path = try std.fs.path.join(temp, &.{ root.path, ".thin/sessions/session.jsonl" });
    const legacy_path = try std.fs.path.join(temp, &.{ root.path, ".thin/logs/session.jsonl" });
    for ([_][]const u8{ ".thin/sessions/session.jsonl", "./.thin//./sessions/session.jsonl", session_path, ".thin/logs/session.jsonl", "./.thin//./logs/session.jsonl", legacy_path }) |path| {
        const args = try std.fmt.allocPrint(temp, "{{\"path\":\"{s}\"}}", .{path});
        const read = try executor.prepare_fn(executor.context, temp, .{ .id = "session", .name = "read_file", .arguments = args });
        try std.testing.expect(read.explicit_denial == null);
        const write_args = try std.fmt.allocPrint(temp, "{{\"path\":\"{s}\",\"content\":\"x\"}}", .{path});
        try std.testing.expectError(error.ProtectedSessionFile, executor.prepare_fn(executor.context, temp, .{ .id = "session", .name = "write_file", .arguments = write_args }));
        try std.testing.expectError(error.FileNotFound, tools.execute(temp, .{ .read_file = .{ .path = path } }, &cancel));
        try std.testing.expectError(error.ProtectedSessionFile, tools.execute(temp, .{ .write_file = .{ .path = path, .content = "x" } }, &cancel));
    }

    // 绝对路径超出工具根目录，必须在 prepare 阶段拒绝。
    try std.testing.expectError(error.OutsideRoot, executor.prepare_fn(executor.context, temp, .{
        .id = "c",
        .name = "write_file",
        .arguments = "{\"path\":\"/outside-not-written\",\"content\":\"x\"}",
    }));

    // 通过 memory 工具的写入只返回需要审批的描述，此时尚未真正写入。
    const action = try executor.prepare_fn(executor.context, temp, .{
        .id = "c",
        .name = "memory",
        .arguments = "{\"action\":\"write\",\"topic\":\"core\",\"content\":\"project fact\"}",
    });
    try std.testing.expect(action.explicit_denial == null);
    try std.testing.expect(std.mem.find(u8, action.description, "project fact") != null);

    // 审批之前不得创建 .thin 目录。
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
}

test "session and log reads retain file safety and credential guards without permitting mutations" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(a, io, buffer[0..n]);
    defer root.deinit();
    var store = mem.Store.init(&root, .{});
    var tools = t.Tools{ .root = &root, .memory = &store, .config = &configuration, .environment = undefined };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    const executor = tools.executor();
    var cancel = p.Cancellation{};

    // Only synthetic temporary files: a text .session exercises permission, not resume decoding.
    try tmp.dir.createDirPath(io, ".thin/sessions");
    try tmp.dir.createDirPath(io, ".thin/logs");
    const content = "{\"text\":\"中文\"}\n";
    for ([_][]const u8{ ".thin/sessions/fake.session", ".thin/sessions/fake.jsonl", ".thin/logs/fake.jsonl" }) |canonical| {
        try root.write(canonical, content, false);
        const absolute = try std.fs.path.join(temp, &.{ root.path, canonical });
        const alias = try std.fmt.allocPrint(temp, "./.thin//./{s}", .{canonical[6..]});
        for ([_][]const u8{ canonical, alias, absolute }) |path| {
            const args = try std.fmt.allocPrint(temp, "{{\"path\":\"{s}\"}}", .{path});
            const prepared = try executor.prepare_fn(executor.context, temp, .{ .id = "read", .name = "read_file", .arguments = args });
            try std.testing.expect(prepared.explicit_denial == null);
            const read = try executor.execute_fn(executor.context, temp, prepared, &cancel);
            const value = try j.parse(temp, read.text);
            try std.testing.expectEqualStrings(content, j.string(j.get(value, "content")).?);
            try std.testing.expectEqual(@as(?u64, content.len), j.uint(j.get(value, "bytes_read")));
            try std.testing.expect(!read.truncated);
            const direct = try tools.execute(temp, .{ .read_file = .{ .path = path } }, &cancel);
            try std.testing.expectEqualStrings(read.text, direct.text);
            for ([_]bool{ false, true }) |overwrite| {
                const write_args = try std.fmt.allocPrint(temp, "{{\"path\":\"{s}\",\"content\":\"not written\",\"overwrite\":{s}}}", .{ path, if (overwrite) "true" else "false" });
                try std.testing.expectError(error.ProtectedSessionFile, executor.prepare_fn(executor.context, temp, .{ .id = "write", .name = "write_file", .arguments = write_args }));
                try std.testing.expectError(error.ProtectedSessionFile, tools.execute(temp, .{ .write_file = .{ .path = path, .content = "not written", .overwrite = overwrite } }, &cancel));
            }
            // No file-delete tool exists. The only structured delete is Memory,
            // whose topic validation must not permit targeting session/log paths.
            const delete_args = try std.fmt.allocPrint(temp, "{{\"action\":\"delete\",\"topic\":\"{s}\",\"expected_version\":\"fake\"}}", .{path});
            try std.testing.expectError(error.InvalidMemoryTopic, executor.prepare_fn(executor.context, temp, .{ .id = "delete", .name = "memory", .arguments = delete_args }));
            try std.testing.expectError(error.InvalidTopic, tools.execute(temp, .{ .memory = .{ .action = .delete, .topic = path, .expected_version = "fake" } }, &cancel));
            try std.testing.expectError(error.UnknownTool, executor.prepare_fn(executor.context, temp, .{ .id = "delete", .name = "delete_file", .arguments = args }));
        }
        const unchanged = try root.read(temp, canonical, 0, 128);
        try std.testing.expectEqualStrings(content, unchanged.data);
    }
    for ([_][]const u8{ ".thin/sessions", "./.thin//./logs" }) |path| {
        try std.testing.expectError(error.ProtectedSessionFile, tools.execute(temp, .{ .write_file = .{ .path = path, .content = "not written", .overwrite = true } }, &cancel));
    }

    const partial = try tools.execute(temp, .{ .read_file = .{ .path = ".thin/logs/fake.jsonl", .offset = 10, .limit = 3 } }, &cancel);
    const partial_value = try j.parse(temp, partial.text);
    try std.testing.expectEqualStrings("中", j.string(j.get(partial_value, "content")).?);
    try std.testing.expectEqual(@as(?u64, 9), j.uint(j.get(partial_value, "offset")));
    try std.testing.expectEqual(@as(?u64, 12), j.uint(j.get(partial_value, "next_offset")));
    try std.testing.expect(partial.truncated and partial.file_stats.?.partial);
    try std.testing.expectError(error.InvalidReadLimit, executor.prepare_fn(executor.context, temp, .{ .id = "large", .name = "read_file", .arguments = "{\"path\":\".thin/logs/fake.jsonl\",\"limit\":99999999}" }));

    // Binary resume frames are NOT converted to text or exempted from validation.
    try tmp.dir.writeFile(io, .{ .sub_path = ".thin/sessions/binary.session", .data = "frame\x00bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".thin/sessions/invalid.session", .data = "\xff" });
    try std.testing.expectError(error.BinaryFile, tools.execute(temp, .{ .read_file = .{ .path = ".thin/sessions/binary.session" } }, &cancel));
    try std.testing.expectError(error.InvalidUtf8, tools.execute(temp, .{ .read_file = .{ .path = ".thin/sessions/invalid.session" } }, &cancel));
    try std.testing.expectError(error.NotRegularFile, tools.execute(temp, .{ .read_file = .{ .path = ".thin/sessions" } }, &cancel));
    try std.testing.expectError(error.InvalidPath, tools.execute(temp, .{ .read_file = .{ .path = ".thin/sessions/../settings.json" } }, &cancel));
    try std.testing.expectError(error.PathEscape, executor.prepare_fn(executor.context, temp, .{ .id = "escape", .name = "read_file", .arguments = "{\"path\":\".thin/sessions/../settings.json\"}" }));
    try std.testing.expectError(error.OutsideRoot, tools.execute(temp, .{ .read_file = .{ .path = "/outside-not-read.session" } }, &cancel));
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("fake.jsonl", root.dir.handle, ".thin/logs/link.jsonl"));
    try std.testing.expectError(error.SymlinkNotAllowed, tools.execute(temp, .{ .read_file = .{ .path = ".thin/logs/link.jsonl" } }, &cancel));
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlinkat("sessions", root.dir.handle, ".thin/linked"));
    try std.testing.expectError(error.NotDir, tools.execute(temp, .{ .read_file = .{ .path = ".thin/linked/fake.session" } }, &cancel));

    // Same auth_path guard for canonical config/credentials and even a protected
    // file located in the newly readable namespace; the read allowance is not an early return.
    for ([_][]const u8{ ".thin/config.json", "credentials.json", ".thin/sessions/private.jsonl" }) |canonical| {
        try root.write(canonical, "fake-key-not-returned", false);
        tools.auth_path = try std.fs.path.join(temp, &.{ root.path, canonical });
        const alias = try std.fmt.allocPrint(temp, "./{s}", .{canonical});
        for ([_][]const u8{ canonical, alias, tools.auth_path.? }) |path| {
            const args = try std.fmt.allocPrint(temp, "{{\"path\":\"{s}\"}}", .{path});
            try std.testing.expectError(error.ProtectedAuthFile, executor.prepare_fn(executor.context, temp, .{ .id = "key", .name = "read_file", .arguments = args }));
            try std.testing.expectError(error.ProtectedAuthFile, tools.execute(temp, .{ .read_file = .{ .path = path } }, &cancel));
            const denied: anyerror = if (std.mem.startsWith(u8, canonical, ".thin/sessions/")) error.ProtectedSessionFile else error.ProtectedAuthFile;
            const write_args = try std.fmt.allocPrint(temp, "{{\"path\":\"{s}\",\"content\":\"not written\",\"overwrite\":true}}", .{path});
            try std.testing.expectError(denied, executor.prepare_fn(executor.context, temp, .{ .id = "key", .name = "write_file", .arguments = write_args }));
            try std.testing.expectError(denied, tools.execute(temp, .{ .write_file = .{ .path = path, .content = "not written", .overwrite = true } }, &cancel));
        }
    }
}

// 验证：文件读取的 offset/limit 按字节计算但不切断 UTF-8 字符，bash 输出中的 UTF-8 保持完整。
test "actual file and command tool results preserve UTF8 and exact continuation offsets" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(a, io, buffer[0..n]);
    defer root.deinit();
    var store = mem.Store.init(&root, .{});
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();

    // 固定 PATH，使命令结果不受宿主环境影响。
    try environment.put("PATH", "/usr/bin:/bin");
    var tools = t.Tools{ .root = &root, .memory = &store, .config = &configuration, .environment = &environment };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();

    var cancel = p.Cancellation{};

    // 文件内容为 a(1 字节) 中(3 字节) 文(3 字节) z(1 字节)；offset=1、limit=4 恰好读出「中」，next_offset 指向下一个字符起点。
    try root.write("text", "a中文z", false);
    const read = try tools.execute(temp, .{ .read_file = .{ .path = "text", .offset = 1, .limit = 4 } }, &cancel);
    const value = try j.parse(temp, read.text);
    try std.testing.expectEqualStrings("中", j.string(j.get(value, "content")).?);
    try std.testing.expectEqual(@as(?u64, 3), j.uint(j.get(value, "bytes_read")));
    try std.testing.expectEqual(@as(?u64, 4), j.uint(j.get(value, "next_offset")));

    // Every interior byte of a four-byte character gives the same true range.
    try root.write("wide", "a😀中z", false);
    for (2..5) |inside| {
        const aligned = try tools.execute(temp, .{ .read_file = .{ .path = "wide", .offset = inside, .limit = 4 } }, &cancel);
        const aligned_value = try j.parse(temp, aligned.text);
        try std.testing.expectEqualStrings("😀", j.string(j.get(aligned_value, "content")).?);
        try std.testing.expectEqual(@as(?u64, 1), j.uint(j.get(aligned_value, "offset")));
        try std.testing.expectEqual(@as(?u64, 4), j.uint(j.get(aligned_value, "bytes_read")));
        const next = j.uint(j.get(aligned_value, "next_offset")).?;
        try std.testing.expectEqual(@as(u64, 5), next);
        try std.testing.expect(aligned.truncated and aligned.file_stats.?.partial);
        const tail = try tools.execute(temp, .{ .read_file = .{ .path = "wide", .offset = next, .limit = 4 } }, &cancel);
        const tail_value = try j.parse(temp, tail.text);
        try std.testing.expectEqualStrings("中z", j.string(j.get(tail_value, "content")).?);
        try std.testing.expectEqual(@as(?u64, 9), j.uint(j.get(tail_value, "next_offset")));
        try std.testing.expect(!tail.truncated);
    }
    // Reporting [partial] must also use the actual range, not the input offset.
    try root.write("first", "中😀a", false);
    const full = try tools.execute(temp, .{ .read_file = .{ .path = "first", .offset = 1, .limit = 64 } }, &cancel);
    const full_value = try j.parse(temp, full.text);
    try std.testing.expectEqualStrings("中😀a", j.string(j.get(full_value, "content")).?);
    try std.testing.expectEqual(@as(?u64, 0), j.uint(j.get(full_value, "offset")));
    try std.testing.expectEqual(@as(?u64, 8), j.uint(j.get(full_value, "next_offset")));
    try std.testing.expect(!full.truncated and !full.file_stats.?.partial);

    // Test author explicitly approves this fixed, harmless local command.
    const command = try tools.execute(temp, .{ .bash = .{ .command = "printf '你好\\n'" } }, &cancel);
    try std.testing.expect(!command.is_error and !command.cleanup_failed);
    const result = try j.parse(temp, command.text);
    try std.testing.expectEqualStrings("你好\n", j.string(j.get(result, "stdout")).?);
    try std.testing.expectEqual(@as(?u64, 0), j.uint(j.get(result, "exit_code")));
}

// 逐个失败分配点注入 OOM：原子提交若已成功，工具必须能返回预先准备的成功结果。
test "mutating file and Memory tool allocation failures precede commits" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Operation = enum { file_create, memory_create, memory_update, memory_delete };
    for ([_]Operation{ .file_create, .memory_create, .memory_update, .memory_delete }) |operation| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path: [4096]u8 = undefined;
        const n = try tmp.dir.realPath(io, &path);
        var root = try fs.Root.open(a, io, path[0..n]);
        defer root.deinit();
        var store = mem.Store.init(&root, .{});
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        var tools = t.Tools{ .root = &root, .memory = &store, .config = &configuration, .environment = &env };
        var setup = std.heap.ArenaAllocator.init(a);
        defer setup.deinit();
        const original: ?mem.Entry = if (operation == .memory_update or operation == .memory_delete)
            try store.write(setup.allocator(), "core", "old", null)
        else
            null;
        const action: t.Action = switch (operation) {
            .file_create => .{ .write_file = .{ .path = "created.txt", .content = "new" } },
            .memory_create => .{ .memory = .{ .action = .write, .topic = "core", .content = "new" } },
            .memory_update => .{ .memory = .{ .action = .write, .topic = "core", .content = "new", .expected_version = original.?.version } },
            .memory_delete => .{ .memory = .{ .action = .delete, .topic = "core", .expected_version = original.?.version } },
        };
        var reached_success = false;
        for (0..256) |fail_index| {
            var attempt = std.heap.ArenaAllocator.init(a);
            defer attempt.deinit();
            var failing = std.testing.FailingAllocator.init(attempt.allocator(), .{ .fail_index = fail_index });
            var cancel = p.Cancellation{};
            const result = tools.execute(failing.allocator(), action, &cancel) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                // 独立分配器读取实际状态，不能让失败注入遮住已经发生的提交。
                var check = std.heap.ArenaAllocator.init(a);
                defer check.deinit();
                switch (operation) {
                    .file_create => try std.testing.expectError(error.FileNotFound, root.read(check.allocator(), "created.txt", 0, 64)),
                    .memory_create => try std.testing.expectError(error.FileNotFound, store.read(check.allocator(), "core")),
                    .memory_update, .memory_delete => {
                        const current = try store.read(check.allocator(), "core");
                        try std.testing.expectEqualStrings("old", current.content);
                        try std.testing.expectEqualStrings(original.?.version, current.version);
                    },
                }
                continue;
            };
            try std.testing.expect(!result.is_error);
            const value = try j.parse(attempt.allocator(), result.text);
            if (operation == .file_create) {
                const current = try root.read(attempt.allocator(), "created.txt", 0, 64);
                try std.testing.expectEqualStrings("new", current.data);
                try std.testing.expectEqual(@as(?u64, 3), j.uint(j.get(value, "written_bytes")));
            } else if (operation == .memory_delete) {
                try std.testing.expectEqualStrings("deleted", j.string(j.get(value, "operation")).?);
                try std.testing.expectError(error.FileNotFound, store.read(attempt.allocator(), "core"));
            } else {
                const current = try store.read(attempt.allocator(), "core");
                try std.testing.expectEqualStrings("new", current.content);
                try std.testing.expectEqualStrings(current.version, j.string(j.get(value, "version")).?);
            }
            reached_success = true;
            break;
        }
        try std.testing.expect(reached_success);
    }
}

test "tools prepare decision inputs without side effects and honor explicit no deadline" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(a, io, buffer[0..n]);
    defer root.deinit();
    var config = configuration;
    config.limits.command_timeout_ms = 1;
    var store = mem.Store.init(&root, config.limits);
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    var tools = t.Tools{ .root = &root, .memory = &store, .config = &config, .environment = &environment };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const executor = tools.executor();
    const write = try executor.prepare_fn(executor.context, alloc, .{
        .id = "memory",
        .name = "memory",
        .arguments = "{\"action\":\"write\",\"topic\":\"style\",\"content\":\"Prefer concise reports.\"}",
    });
    try std.testing.expectEqualStrings("style", write.decision_input.?.memory_write.topic);
    try std.testing.expect(write.explicit_denial == null);
    try std.testing.expectError(error.FileNotFound, store.read(alloc, "style"));
    const list = try executor.prepare_fn(executor.context, alloc, .{ .id = "list", .name = "memory", .arguments = "{\"action\":\"list\"}" });
    try std.testing.expect(list.decision_input == null);
    var cancel = p.Cancellation{};
    for ([_]@import("../core/decision.zig").Timeout{ .none, .{ .milliseconds = 1000 } }) |timeout| {
        var prepared = try executor.prepare_fn(executor.context, alloc, .{
            .id = "command",
            .name = "bash",
            .arguments = "{\"command\":\"sleep 0.02; printf ready\"}",
        });
        try std.testing.expectEqual(@as(u32, config.limits.command_max_timeout_ms), prepared.decision_input.?.command.max_timeout_ms);
        prepared.command_timeout = timeout;
        const result = try executor.execute_fn(executor.context, alloc, prepared, &cancel);
        try std.testing.expect(!result.is_error);
        const value = try j.parse(alloc, result.text);
        try std.testing.expectEqualStrings("ready", j.string(j.get(value, "stdout")).?);
        try std.testing.expectEqual(false, j.get(value, "timed_out").?.bool);
    }
}
