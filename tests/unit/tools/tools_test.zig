test "bash batch parses independent commands and rejects mixed modes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const batch = try parse(a, "bash", "{\"commands\":[{\"command\":\"printf one\"},{\"command\":\"printf two\",\"timeout_ms\":5000}]}", .{});
    try std.testing.expect(batch.bash.command.len == 0);
    try std.testing.expectEqual(@as(usize, 2), batch.bash.commands.len);
    try std.testing.expectEqualStrings("printf two", batch.bash.commands[1].command);
    try std.testing.expectEqual(@as(?u32, 5000), batch.bash.commands[1].timeout_ms);
    try std.testing.expectError(error.InvalidCommand, parse(a, "bash", "{\"command\":\"true\",\"commands\":[{\"command\":\"true\"}]}", .{}));
    try std.testing.expectError(error.InvalidCommand, parse(a, "bash", "{}", .{}));
    try std.testing.expectError(error.InvalidCommand, parse(a, "bash", "{\"commands\":[{\"command\":\"true\"}],\"background\":true}", .{}));
    try std.testing.expectError(error.InvalidCommandTimeout, parse(a, "bash", "{\"commands\":[{\"command\":\"true\",\"timeout_ms\":0}]}", .{}));
    const entry = "{\"command\":\"true\"}";
    var max_entries: [20][]const u8 = undefined;
    for (&max_entries) |*item| item.* = entry;
    const max_joined = try std.mem.join(a, ",", &max_entries);
    const max_batch = try std.fmt.allocPrint(a, "{{\"commands\":[{s}]}}", .{max_joined});
    try std.testing.expectEqual(@as(usize, 20), (try parse(a, "bash", max_batch, .{})).bash.commands.len);
    var entries: [21][]const u8 = undefined;
    for (&entries) |*item| item.* = entry;
    const joined = try std.mem.join(a, ",", &entries);
    const too_many = try std.fmt.allocPrint(a, "{{\"commands\":[{s}]}}", .{joined});
    try std.testing.expectError(error.InvalidCommand, parse(a, "bash", too_many, .{}));
}

test "bash batch returns ordered bounded results and rejects high-risk batches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
    defer root.deinit();
    const config: cfg.Config = .{ .provider = .{ .base_url = "http://127.0.0.1" }, .model = .{ .name = "fake", .context_tokens = 10000 } };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tools: Tools = .{ .root = &root, .memory = undefined, .config = &config, .environment = &env };
    var cancel: p.Cancellation = .{};
    const commands = [_]BashCommand{
        .{ .command = "printf one" },
        .{ .command = "printf two" },
        .{ .command = "sh -c 'exit 3'" },
        .{ .command = "printf four" },
        .{ .command = "printf five" },
        .{ .command = "printf six" },
    };
    const result = try tools.execute(a, .{ .bash = .{ .commands = &commands } }, &cancel);
    try std.testing.expect(result.is_error);
    try std.testing.expect(!result.canceled);
    try std.testing.expect(!result.memory_evidence);
    const json = try std.json.parseFromSliceLeaky(std.json.Value, a, result.text, .{});
    const rows = json.object.get("commands").?.array.items;
    try std.testing.expectEqual(@as(usize, 6), rows.len);
    try std.testing.expectEqualStrings("one", rows[0].object.get("stdout").?.string);
    try std.testing.expectEqualStrings("two", rows[1].object.get("stdout").?.string);
    try std.testing.expectEqual(@as(i64, 3), rows[2].object.get("exit_code").?.integer);
    try std.testing.expect(rows[2].object.get("failed").?.bool);
    try std.testing.expectEqualStrings("four", rows[3].object.get("stdout").?.string);
    try std.testing.expectEqualStrings("five", rows[4].object.get("stdout").?.string);
    try std.testing.expectEqualStrings("six", rows[5].object.get("stdout").?.string);
    try std.testing.expectError(error.HighRiskBatch, Tools.prepare(&tools, a, .{ .id = "b", .name = "bash", .arguments = "{\"commands\":[{\"command\":\"rm -rf /\"}]}" }));
}

test "bash batch starts independent commands concurrently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
    defer root.deinit();
    const config: cfg.Config = .{ .provider = .{ .base_url = "http://127.0.0.1" }, .model = .{ .name = "fake", .context_tokens = 10000 } };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tools: Tools = .{ .root = &root, .memory = undefined, .config = &config, .environment = &env };
    var cancel: p.Cancellation = .{};
    const first_cmd = try std.fmt.allocPrint(a, "/usr/bin/touch {s}/first; while [ ! -f {s}/second ]; do /bin/sleep 0.01; done", .{ root.path, root.path });
    const second_cmd = try std.fmt.allocPrint(a, "while [ ! -f {s}/first ]; do /bin/sleep 0.01; done; /usr/bin/touch {s}/second", .{ root.path, root.path });
    const commands = [_]BashCommand{
        .{ .command = first_cmd },
        .{ .command = second_cmd },
    };
    const result = try tools.execute(a, .{ .bash = .{ .commands = &commands, .timeout_ms = 2000 } }, &cancel);
    try std.testing.expect(!result.is_error);
    _ = try root.dir.statFile(std.testing.io, "first", .{});
    _ = try root.dir.statFile(std.testing.io, "second", .{});
}

test "tool schemas have stable order and valid JSON" {
    try std.testing.expectEqualStrings("read_file", schemas[0].name);
    try std.testing.expectEqualStrings("memory", schemas[3].name);

    for (schemas) |schema| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema.parameters_json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
    }
}
test "edit parsing accepts more than 128 edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const item = "{\"old_text\":\"a\",\"new_text\":\"b\"},";
    const count = 160;
    const prefix = try a.alloc(u8, item.len * (count - 1));
    for (0..count - 1) |i| @memcpy(prefix[i * item.len ..][0..item.len], item);
    const suffix = "{\"old_text\":\"a\",\"new_text\":\"b\"}";
    const at_limit = try std.fmt.allocPrint(a, "{{\"path\":\"a\",\"edits\":[{s}{s}]}}", .{ prefix, suffix });
    const valid = try parse(a, "edit_file", at_limit, .{});
    try std.testing.expectEqual(@as(usize, count), valid.edit_file.edits.len);
}
test "memory prepare carries its parsed payload and no review input" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, io, buffer[0..n]);
    defer root.deinit();
    const config: cfg.Config = .{ .provider = .{ .base_url = "http://127.0.0.1" }, .model = .{ .name = "fake", .context_tokens = 10000 } };
    var tools: Tools = .{ .root = &root, .memory = undefined, .config = &config, .environment = undefined };
    const selected = tools.executor().schemas;
    try std.testing.expectEqualStrings(schemas[2].description, selected[2].description);
    try std.testing.expectEqualStrings(schemas[3].description, selected[3].description);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const calls = [_][]const u8{
        "{\"action\":\"write\",\"topic\":\"notes\",\"content\":\"durable fact\"}",
        "{\"action\":\"read\",\"topic\":\"notes\"}",
        "{\"action\":\"delete\",\"topic\":\"notes\"}",
        "{\"action\":\"write\",\"topic\":\"notes.md\",\"content\":\"durable fact\"}",
        "{\"action\":\"read\",\"topic\":\"notes.md\"}",
        "{\"action\":\"delete\",\"topic\":\"notes.md\"}",
        "{\"action\":\"list\"}",
    };
    for (calls) |arguments| {
        const prepared = try Tools.prepare(&tools, a, .{ .id = "m", .name = "memory", .arguments = arguments });
        const action: *const Action = @ptrCast(@alignCast(prepared.payload));
        try std.testing.expect(action.* == .memory);
        // The on-disk `.md` suffix is accepted and normalized for the store.
        if (action.memory.action != .list) try std.testing.expectEqualStrings("notes", action.memory.topic.?);
        if (action.memory.action == .write) try std.testing.expectEqualStrings("durable fact", action.memory.content.?);
    }
}
test "prepare reports the one file a write or edit will change" {
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
    const write = try Tools.prepare(&tools, a, .{ .id = "w", .name = "write_file", .arguments = "{\"path\":\"a.zig\",\"content\":\"x\"}" });
    try std.testing.expectEqualStrings("a.zig", write.edited_path.?);
    const edit = try Tools.prepare(&tools, a, .{ .id = "e", .name = "edit_file", .arguments = "{\"path\":\"a.zig\",\"edits\":[{\"old_text\":\"x\",\"new_text\":\"y\"}]}" });
    try std.testing.expectEqualStrings("a.zig", edit.edited_path.?);
    const read = try Tools.prepare(&tools, a, .{ .id = "r", .name = "read_file", .arguments = "{\"path\":\"a.zig\"}" });
    try std.testing.expect(read.edited_path == null);
}
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
    try std.testing.expectEqual(@as(?usize, 99999999), (try parse(a, "read_file", "{\"path\":\"a\",\"limit\":99999999}", .{})).read_file.limit);
    try std.testing.expectError(error.UnknownField, parse(a, "bash", "{\"command\":\"true\",\"trust\":true}", .{}));
}
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
test "project settings exact aliases protected at prepared and direct execute" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, io, buffer[0..n]);
    defer root.deinit();
    const config: cfg.Config = .{ .provider = .{ .base_url = "http://127.0.0.1" }, .model = .{ .name = "fake", .context_tokens = 10000 } };
    var tools: Tools = .{ .root = &root, .memory = undefined, .config = &config, .environment = undefined };
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(root.dir.handle, ".thin", 0o700));
    try root.writeMode(settings.relative_path, "private", false, 0o600);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const absolute = try std.fs.path.join(a, &.{ root.path, ".thin/./settings.json" });
    var cancel: p.Cancellation = .{};
    for ([_][]const u8{ settings.relative_path, "./.thin//./settings.json", ".thin/./settings.json/.", absolute }) |path| {
        // Read authorization is descriptor-based so aliases and hard links are
        // rejected against the same opened inode, not guessed during prepare.
        try tools.checkFileAction(a, .{ .read_file = .{ .path = path } });
        const direct_error = if (tools.execute(a, .{ .read_file = .{ .path = path } }, &cancel)) |_| return error.ExpectedProtectedRead else |err| err;
        try std.testing.expect(direct_error == error.ProtectedSettingsFile or direct_error == error.NotDir or direct_error == error.FileNotFound);
        try std.testing.expectError(error.ProtectedSettingsFile, tools.execute(a, .{ .write_file = .{ .path = path, .content = "x" } }, &cancel));
        const read_args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\"}}", .{path});
        const write_args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\",\"content\":\"x\"}}", .{path});
        const executor = tools.executor();
        const prepared = try executor.prepare_fn(executor.context, a, .{ .id = "r", .name = "read_file", .arguments = read_args });
        try std.testing.expectError(direct_error, executor.execute_fn(executor.context, a, prepared, &cancel));
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
test "write preview baseline is one-shot read only missing-safe and protected" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, io, buffer[0..n]);
    defer root.deinit();
    const config: cfg.Config = .{ .provider = .{ .base_url = "http://127.0.0.1" }, .model = .{ .name = "fake", .context_tokens = 10000 } };
    var tools: Tools = .{ .root = &root, .memory = undefined, .config = &config, .environment = undefined };
    var cancel: p.Cancellation = .{};

    var missing = (try Tools.previewWrite(&tools, std.testing.allocator, "missing.txt", &cancel)).?;
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.lines.len);
    try std.testing.expectError(error.FileNotFound, root.readBinary(std.testing.allocator, "missing.txt", 1));

    try root.writeMode("existing.txt", "old\ncontent", false, 0o600);
    const before = try root.dir.statFile(io, "existing.txt", .{});
    var baseline = (try Tools.previewWrite(&tools, std.testing.allocator, "existing.txt", &cancel)).?;
    defer baseline.deinit();
    try std.testing.expectEqual(@as(usize, 2), baseline.lines.len);
    const after = try root.dir.statFile(io, "existing.txt", .{});
    try std.testing.expectEqual(before.size, after.size);
    try std.testing.expectEqualDeep(before.mtime, after.mtime);

    cancel.cancel();
    try std.testing.expect((try Tools.previewWrite(&tools, std.testing.allocator, "existing.txt", &cancel)) == null);
    var active: p.Cancellation = .{};
    try std.testing.expectError(error.ProtectedSettingsFile, Tools.previewWrite(&tools, std.testing.allocator, settings.relative_path, &active));
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdirat(root.dir.handle, ".thin", 0o700));
    try root.writeMode(settings.relative_path, "private", false, 0o600);
    try std.testing.expectEqual(@as(c_int, 0), std.c.linkat(root.dir.handle, ".thin/settings.json", root.dir.handle, "settings-alias.txt", 0));
    try std.testing.expectError(error.ProtectedSettingsFile, root.readBinaryGuarded(std.testing.allocator, "settings-alias.txt", 1024, tools.textReadGuard()));
    try std.testing.expect((try Tools.previewWrite(&tools, std.testing.allocator, "settings-alias.txt", &active)) == null);
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

    const dangerous = try Tools.prepare(&tools, a, .{ .id = "d", .name = "bash", .arguments = "{\"command\":\"rm -f .ssh/fixture-marker\"}" });
    try std.testing.expect(dangerous.explicit_denial != null);
    try std.testing.expect(std.mem.indexOf(u8, dangerous.explicit_denial.?, "sensitive") != null);
    try std.testing.expect(std.mem.indexOf(u8, dangerous.explicit_denial.?, "explicit user allow each time") != null);
    try std.testing.expect(std.mem.indexOf(u8, dangerous.description, "$ rm -f .ssh/fixture-marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, dangerous.description, "DANGEROUS") == null);

    const safe = try Tools.prepare(&tools, a, .{ .id = "s", .name = "bash", .arguments = "{\"command\":\"rm -rf build\"}" });
    try std.testing.expect(safe.explicit_denial == null);
    try std.testing.expect(std.mem.indexOf(u8, safe.description, "DANGEROUS") == null);
}
test "image tool strict arguments schemas guards and bounded text output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const off = schemasForServices(false);
        const on = schemasForServices(true);
        try std.testing.expectEqual(@as(usize, 5), off.len);
        try std.testing.expectEqual(@as(usize, 6), on.len);
        for (off[0..4], on[0..4]) |old, new| {
            try std.testing.expectEqualStrings(old.name, new.name);
            try std.testing.expectEqualStrings(old.description, new.description);
            try std.testing.expectEqualStrings(old.parameters_json, new.parameters_json);
        }
        try std.testing.expectEqualStrings("read_image", on[4].name);
        try std.testing.expectEqualStrings("edit_file", off[4].name);
        try std.testing.expectEqualStrings("edit_file", on[5].name);
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
test "background schema is appended last and old schemas keep indexes" {
    {
        const off = schemasFor(true, true, false);
        const on = schemasFor(true, true, true);
        try std.testing.expectEqual(@as(usize, 6), off.len);
        try std.testing.expectEqual(@as(usize, 7), on.len);
        try std.testing.expectEqualStrings("read_image", off[4].name);
        try std.testing.expectEqualStrings("read_image", on[4].name);
        for (off[0..5], on[0..5]) |old, new| try std.testing.expectEqualStrings(old.name, new.name);
        try std.testing.expectEqualStrings("background", on[5].name);
        try std.testing.expectEqualStrings("edit_file", off[5].name);
        try std.testing.expectEqualStrings("edit_file", on[6].name);
        // A Tools without a service keeps the old bash parameters exactly.
        try std.testing.expect(std.mem.indexOf(u8, off[2].parameters_json, "background") == null);
        try std.testing.expect(std.mem.indexOf(u8, on[2].parameters_json, "\"background\":{\"type\":\"boolean\"}") != null);
        try std.testing.expect(std.mem.indexOf(u8, on[2].description, "not how long the service keeps running") != null or
            std.mem.indexOf(u8, on[2].description, "after handoff the service keeps running until it is stopped or Thin exits") != null);
        for ([_]p.ToolSchema{ on[2], on[5] }) |schema| {
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema.parameters_json, .{});
            defer parsed.deinit();
            try std.testing.expect(parsed.value == .object);
        }
    }
    // The management tool stays appended after the ordinary schemas.
    const root_only = schemasFor(true, true, true);
    try std.testing.expectEqual(@as(usize, 7), root_only.len);
    try std.testing.expectEqualStrings("background", root_only[5].name);
}
test "background bash and management arguments stay strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plain = try parse(a, "bash", "{\"command\":\"true\"}", .{});
    try std.testing.expect(!plain.bash.background);
    const bg = try parse(a, "bash", "{\"command\":\"true\",\"background\":true}", .{});
    try std.testing.expect(bg.bash.background);
    // 严格 bool：数字/null 不能被当成 true/false 接受。
    if (parse(a, "bash", "{\"command\":\"true\",\"background\":1}", .{})) |_| return error.ExpectedStrictBackground else |_| {}
    if (parse(a, "bash", "{\"command\":\"true\",\"background\":null}", .{})) |_| return error.ExpectedStrictBackground else |_| {}
    // Commands beyond the former 32KiB cap remain complete in both modes.
    const long = try a.alloc(u8, 32769);
    @memset(long, 'a');
    const long_args = try std.fmt.allocPrint(a, "{{\"command\":\"{s}\"}}", .{long});
    try std.testing.expectEqualSlices(u8, long, (try parse(a, "bash", long_args, .{})).bash.command);
    const long_bg = try std.fmt.allocPrint(a, "{{\"command\":\"{s}\",\"background\":true}}", .{long});
    const accepted_bg = try parse(a, "bash", long_bg, .{});
    try std.testing.expect(accepted_bg.bash.background);
    try std.testing.expectEqualSlices(u8, long, accepted_bg.bash.command);
    try std.testing.expectError(error.InvalidCommand, parse(a, "bash", "{\"command\":\"\"}", .{}));
    try std.testing.expectError(error.InvalidCommand, parse(a, "bash", "{\"command\":\"a\\u0000b\"}", .{}));
    if (parse(a, "bash", "{\"command\":\"\xff\"}", .{})) |_| return error.ExpectedInvalidUtf8 else |_| {}

    const logs = try parse(a, "background", "{\"action\":\"logs\",\"id\":\"0123456789ab-1\",\"stdout_offset\":4,\"limit\":128}", .{});
    try std.testing.expect(logs.background.action == .logs);
    try std.testing.expectEqual(@as(u64, 4), logs.background.stdout_offset.?);
    try std.testing.expectError(error.InvalidBackgroundQuery, parse(a, "background", "{\"action\":\"list\",\"extra\":1}", .{}));
    try std.testing.expectError(error.InvalidBackgroundQuery, parse(a, "background", "{\"action\":\"list\",\"id\":\"0123456789ab-1\"}", .{}));
    const large_list = try parse(a, "background", "{\"action\":\"list\",\"limit\":101}", .{});
    try std.testing.expectEqual(@as(?usize, 101), large_list.background.limit);
    const large_logs = try parse(a, "background", "{\"action\":\"logs\",\"id\":\"0123456789ab-1\",\"limit\":67108865}", .{});
    try std.testing.expectEqual(@as(?usize, 67108865), large_logs.background.limit);
    try std.testing.expectError(error.InvalidBackgroundQuery, parse(a, "background", "{\"action\":\"unknown\"}", .{}));
    try std.testing.expectError(error.InvalidBackgroundQuery, parse(a, "background", "{\"action\":\"list\",\"limit\":0}", .{}));
    try std.testing.expectError(error.InvalidBackgroundQuery, parse(a, "background", "{\"action\":\"status\"}", .{}));
    for ([_][]const u8{ "", "a\\u0000b", "\xff" }) |id| {
        const invalid_id = try std.fmt.allocPrint(a, "{{\"action\":\"status\",\"id\":\"{s}\"}}", .{id});
        try std.testing.expectError(error.InvalidBackgroundQuery, parse(a, "background", invalid_id, .{}));
    }
    try std.testing.expectError(error.InvalidBackgroundQuery, parse(a, "background", "{\"action\":\"stop\",\"id\":\"0123456789ab-1\",\"after\":0}", .{}));
    try std.testing.expectError(error.InvalidBackgroundQuery, parse(a, "background", "{\"action\":\"logs\",\"id\":\"ABCDEF012345-1\"}", .{}));
}
test "background capability is root-only approved and never re-encoded" {
    const config: cfg.Config = .{ .provider = .{ .base_url = "http://127.0.0.1" }, .model = .{ .name = "fake", .context_tokens = 10000 } };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: FakeBackground = .{};
    var tools: Tools = .{ .root = undefined, .memory = undefined, .config = &config, .environment = &env };
    var cancel: p.Cancellation = .{};

    // No registry: forged background start and the management tool fail before I/O.
    try std.testing.expectError(error.BackgroundDisabled, tools.execute(a, .{ .bash = .{ .command = "true", .background = true } }, &cancel));
    try std.testing.expectError(error.BackgroundDisabled, tools.execute(a, .{ .background = .{ .action = .list } }, &cancel));
    try std.testing.expectError(error.BackgroundDisabled, Tools.prepare(&tools, a, .{ .id = "b", .name = "bash", .arguments = "{\"command\":\"true\",\"background\":true}" }));
    try std.testing.expectError(error.BackgroundDisabled, Tools.prepare(&tools, a, .{ .id = "m", .name = "background", .arguments = "{\"action\":\"list\"}" }));

    // Root service: prepare stays pure but still carries risk/review metadata.
    tools.background = fake.service();
    const prepared = try Tools.prepare(&tools, a, .{ .id = "b", .name = "bash", .arguments = "{\"command\":\"rm -f .ssh/fixture-marker\",\"background\":true}" });
    try std.testing.expect(prepared.explicit_denial != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.description, "$ rm -f .ssh/fixture-marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.description, "DANGEROUS") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.description, "background service") != null);
    try std.testing.expectEqual(@as(usize, 0), fake.checks);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    const managed = try Tools.prepare(&tools, a, .{ .id = "m", .name = "background", .arguments = "{\"action\":\"status\",\"id\":\"0123456789ab-1\"}" });
    const managed_action: *const Action = @ptrCast(@alignCast(managed.payload));
    try std.testing.expect(managed_action.* == .background);
    try std.testing.expectEqual(@as(usize, 0), fake.checks);

    // Cancellation during the bounded startup wait never starts a service. The
    // existing early-cancel semantics are an Execution result, not an error.
    cancel.cancel();
    const canceled_early = try tools.execute(a, .{ .bash = .{ .command = "svc", .background = true } }, &cancel);
    try std.testing.expect(canceled_early.canceled);
    try std.testing.expect(canceled_early.is_error);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    cancel = .{};

    // Start maps the configured finite startup budget, log capacity and cleanup policy.
    const started = try tools.execute(a, .{ .bash = .{ .command = "python -u app.py", .background = true } }, &cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("python -u app.py", fake.last_command);
    try std.testing.expectEqual(@as(u32, config.limits.command_timeout_ms), fake.last_startup_ms);
    try std.testing.expectEqual(@as(u32, cfg.Policy.cleanup_grace_ms), fake.last_grace_ms);
    try std.testing.expectEqual(@as(u32, cfg.Policy.cleanup_timeout_ms), fake.last_cleanup_ms);
    try std.testing.expectEqualStrings(fake.start_text, started.text);
    try std.testing.expect(!started.memory_evidence);
    try std.testing.expect(!started.is_error);

    // Explicit timeout_ms bounds only the startup wait, just like the default.
    for ([_]u32{ 1, 4321, 86_400_001 }) |timeout_ms| {
        const args = try std.fmt.allocPrint(a, "{{\"command\":\"svc\",\"background\":true,\"timeout_ms\":{d}}}", .{timeout_ms});
        const explicit = try Tools.prepare(&tools, a, .{ .id = "b", .name = "bash", .arguments = args });
        _ = try Tools.executePrepared(&tools, a, explicit, &cancel);
        try std.testing.expectEqual(timeout_ms, fake.last_startup_ms);
    }
    const calls_before_invalid = fake.calls;
    try std.testing.expectError(error.InvalidCommandTimeout, Tools.prepare(&tools, a, .{ .id = "b", .name = "bash", .arguments = "{\"command\":\"svc\",\"background\":true,\"timeout_ms\":0}" }));
    try std.testing.expectEqual(calls_before_invalid, fake.calls);

    // stop returns the service's terminal state verbatim; stopping one service
    // is not caller cancellation and must not mark this Q&A canceled.
    const stopped = try tools.execute(a, .{ .background = .{ .action = .stop, .id = "0123456789ab-1" } }, &cancel);
    try std.testing.expectEqualStrings(fake.control_text, stopped.text);
    try std.testing.expect(!stopped.canceled);
    try std.testing.expect(!stopped.is_error);
    try std.testing.expect(!stopped.memory_evidence);
    try std.testing.expect(fake.last_query.action == .stop);

    // A cleanup failure is returned verbatim and poisons; no re-encoding.
    fake.cleanup_failed = true;
    const failed = try tools.execute(a, .{ .bash = .{ .command = "svc", .background = true } }, &cancel);
    try std.testing.expect(failed.cleanup_failed);
    try std.testing.expect(failed.is_error);
    try std.testing.expectEqualStrings(fake.start_text, failed.text);
    fake.cleanup_failed = false;

    // A poisoned service fails ordinary tools and both lifecycle hooks without
    // stopping the already handed-off service.
    fake.poisoned = true;
    const controls_before = fake.controls;
    try std.testing.expectError(error.CleanupFailed, tools.execute(a, .{ .read_file = .{ .path = "x" } }, &cancel));
    try std.testing.expectError(error.CleanupFailed, Tools.endTask(&tools, &cancel));
    try std.testing.expectEqual(controls_before, fake.controls);
    fake.poisoned = false;

    // Default foreground bash is unchanged and never calls the background service.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
    defer root.deinit();
    tools.root = &root;
    const calls_before = fake.calls;
    const foreground = try tools.execute(a, .{ .bash = .{ .command = "printf ok" } }, &cancel);
    try std.testing.expectEqual(calls_before, fake.calls);
    try std.testing.expect(!foreground.is_error);
    const fg = try std.json.parseFromSliceLeaky(std.json.Value, a, foreground.text, .{});
    try std.testing.expectEqualStrings("ok", fg.object.get("stdout").?.string);
    try std.testing.expect(fg.object.get("id") == null);
}
test "single bash command output is capped and reports the real size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
    defer root.deinit();
    const config: cfg.Config = .{ .provider = .{ .base_url = "http://127.0.0.1" }, .model = .{ .name = "fake", .context_tokens = 10000 } };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tools: Tools = .{ .root = &root, .memory = undefined, .config = &config, .environment = &env };
    var cancel: p.Cancellation = .{};

    const ex = tools.executor();
    const begin = ex.begin_batch_fn.?;

    // A matched line in a large file can be megabytes long; one command must not
    // be able to dominate the input budget.
    begin(ex.context);
    const result = try tools.execute(a, .{ .bash = .{ .command = "yes line | head -c 200000" } }, &cancel);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.truncated);
    const json = try std.json.parseFromSliceLeaky(std.json.Value, a, result.text, .{});
    try std.testing.expectEqual(@as(i64, 200000), json.object.get("stdout_bytes").?.integer);
    try std.testing.expect(json.object.get("truncated").?.bool);
    const stdout = json.object.get("stdout").?.string;
    // The capture budget is shared by stdout and stderr, so one stream keeps
    // half of the 64 KiB option.
    try std.testing.expect(stdout.len <= 32 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, stdout, "[...]") != null);

    // Output under the budget stays complete and unmarked.
    begin(ex.context);
    const small = try tools.execute(a, .{ .bash = .{ .command = "printf tiny" } }, &cancel);
    try std.testing.expect(!small.is_error);
    try std.testing.expect(!small.truncated);
    const small_json = try std.json.parseFromSliceLeaky(std.json.Value, a, small.text, .{});
    try std.testing.expectEqualStrings("tiny", small_json.object.get("stdout").?.string);
    try std.testing.expect(!small_json.object.get("truncated").?.bool);
}
test "blob-shaped bash output is condensed with facts and a narrowing hint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
    defer root.deinit();
    const config: cfg.Config = .{ .provider = .{ .base_url = "http://127.0.0.1" }, .model = .{ .name = "fake", .context_tokens = 10000 } };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tools: Tools = .{ .root = &root, .memory = undefined, .config = &config, .environment = &env };
    var cancel: p.Cancellation = .{};

    const ex = tools.executor();
    const begin = ex.begin_batch_fn.?;

    // One enormous line: a head/tail pair would keep the least useful bytes, so
    // the result keeps a short head plus the real size and how to narrow it.
    begin(ex.context);
    const blob = try tools.execute(a, .{ .bash = .{ .command = "head -c 200000 /dev/zero | tr '\\0' a" } }, &cancel);
    try std.testing.expect(!blob.is_error);
    try std.testing.expect(blob.truncated);
    const blob_json = try std.json.parseFromSliceLeaky(std.json.Value, a, blob.text, .{});
    try std.testing.expectEqual(@as(i64, 200000), blob_json.object.get("stdout_bytes").?.integer);
    const blob_out = blob_json.object.get("stdout").?.string;
    try std.testing.expect(blob_out.len < 4096);
    try std.testing.expect(std.mem.indexOf(u8, blob_out, "thin: 200000 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob_out, "Narrow with grep -c/-o or head -c") != null);
    try std.testing.expect(blob_json.object.get("truncated").?.bool);

    // Escape-heavy binary output is condensed the same way, even though its
    // lines are meaningless.
    begin(ex.context);
    const binary = try tools.execute(a, .{ .bash = .{ .command = "head -c 200000 /dev/urandom" } }, &cancel);
    try std.testing.expect(!binary.is_error);
    const binary_json = try std.json.parseFromSliceLeaky(std.json.Value, a, binary.text, .{});
    const binary_out = binary_json.object.get("stdout").?.string;
    try std.testing.expect(binary_out.len < 4096);
    try std.testing.expect(std.mem.indexOf(u8, binary_out, "binary-like") != null);
    try std.testing.expect(binary_json.object.get("truncated").?.bool);

    // A complete single line under the cap is the caller's data: keep it whole.
    begin(ex.context);
    const line = try tools.execute(a, .{ .bash = .{ .command = "head -c 20000 /dev/zero | tr '\\0' a" } }, &cancel);
    try std.testing.expect(!line.is_error);
    try std.testing.expect(!line.truncated);
    const line_json = try std.json.parseFromSliceLeaky(std.json.Value, a, line.text, .{});
    try std.testing.expectEqual(@as(usize, 20000), line_json.object.get("stdout").?.string.len);
    try std.testing.expect(!line_json.object.get("truncated").?.bool);
}
test "one tool batch shares the round output budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buffer);
    var root = try fs.Root.open(std.testing.allocator, std.testing.io, buffer[0..n]);
    defer root.deinit();
    const config: cfg.Config = .{ .provider = .{ .base_url = "http://127.0.0.1" }, .model = .{ .name = "fake", .context_tokens = 10000 } };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tools: Tools = .{ .root = &root, .memory = undefined, .config = &config, .environment = &env };
    var cancel: p.Cancellation = .{};

    // Several calls in one response must not add up to the flood a single call
    // is capped for, and the last one keeps a floor so it can still report size.
    const ex = tools.executor();
    const begin = ex.begin_batch_fn.?;
    begin(ex.context);
    var sizes: [3]usize = undefined;
    for (&sizes) |*size| {
        const result = try tools.execute(a, .{ .bash = .{ .command = "yes line | head -c 100000" } }, &cancel);
        try std.testing.expect(result.truncated);
        const json = try std.json.parseFromSliceLeaky(std.json.Value, a, result.text, .{});
        try std.testing.expectEqual(@as(i64, 100000), json.object.get("stdout_bytes").?.integer);
        size.* = json.object.get("stdout").?.string.len;
    }
    try std.testing.expect(sizes[0] <= 32 * 1024 and sizes[0] > 0);
    try std.testing.expect(sizes[1] <= 32 * 1024 and sizes[1] > 0);
    try std.testing.expect(sizes[0] + sizes[1] <= 64 * 1024);
    try std.testing.expect(sizes[2] <= 512 and sizes[2] > 0);

    // The next batch starts from a full budget again.
    begin(ex.context);
    const fresh = try tools.execute(a, .{ .bash = .{ .command = "yes line | head -c 100000" } }, &cancel);
    const fresh_json = try std.json.parseFromSliceLeaky(std.json.Value, a, fresh.text, .{});
    try std.testing.expect(fresh_json.object.get("stdout").?.string.len > 16 * 1024);
}
