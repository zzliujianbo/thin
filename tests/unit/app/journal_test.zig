// Fixture read windows, not product limits.
const record_limit: usize = 32 * 1024 * 1024;
const text_limit: usize = 1024 * 1024;

test "selection snapshots are lazy ordered and save the last switch without another submission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    const id = "0123456789abcdef0123456789abcdef".*;
    try journal.pinSessionID(id);
    var config: @import("../core/config.zig").Config = .{
        .provider = .{ .base_url = "https://fixture.invalid/v1" },
        .model = .{ .name = "first-fixture", .protocol = .chat, .context_tokens = 32768 },
    };
    journal.setSelection(selections.capture(config));
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    journal.observer().notify(.{ .submitted = "fixture goal" });
    config.model.name = "last-fixture";
    config.model.protocol = .responses;
    config.model.reasoning_effort = "high";
    journal.setSelection(selections.capture(config));
    journal.flush();
    try std.testing.expect(journal.failure() == null);
    const data = try root.read(std.testing.allocator, journal.store.path(), 0, 8192);
    defer std.testing.allocator.free(data.data);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, data.data, "\"event\":\"selection\""));
    try std.testing.expect(std.mem.indexOf(u8, data.data, "\"model\":\"last-fixture\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data.data, "\"protocol\":\"responses\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data.data, "\"effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, data.data, "https://fixture.invalid") == null);
    try std.testing.expect(std.mem.find(u8, data.data, ".selection.json") == null);
    config.model.name = "prefix-fake-key-suffix";
    journal.setSelection(selections.capture(config));
    try std.testing.expectEqual(error.SensitiveSelection, journal.failure().?);
    try std.testing.expect(std.mem.find(u8, data.data, "prefix-fake-key-suffix") == null);
}
test "selection before start creates no snapshot or archive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    const config: @import("../core/config.zig").Config = .{
        .provider = .{ .base_url = "https://fixture.invalid/v1" },
        .model = .{ .name = "fixture", .context_tokens = 32768 },
    };
    journal.setSelection(selections.capture(config));
    journal.setSelection(selections.capture(config));
    journal.finish();
    try std.testing.expect(journal.failure() == null);
    try std.testing.expectEqual(@as(u64, 0), journal.seq);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
}
test "journal retains multiple keys and redacts overlapping and encoded credentials" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(a, &root, "fake-key");
    defer journal.deinit();
    try journal.rememberKey("fake-key-longer");
    try journal.rememberKey("other-key");
    try journal.rememberKey("other-key");
    try std.testing.expectEqual(@as(usize, 2), journal.known_keys.items.len);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    try std.testing.expectEqualStrings("[redacted] [redacted] [redacted]", try journal.safe(temp, "fake-key-longer other-key fake-key"));
    const encoded = try journal.jsonText(temp, "{\"key\":\"other\\u002dkey\"}");
    try std.testing.expectEqualStrings("{\"key\":\"[redacted]\"}", encoded.text);
    try std.testing.expectError(error.InvalidApiKey, journal.rememberKey("bad\nkey"));
    for (2..24) |index| {
        var buffer: [40]u8 = undefined;
        try journal.rememberKey(try std.fmt.bufPrint(&buffer, "fake-rotation-{d}", .{index}));
    }
    try journal.rememberKey("fake-excess");
    try journal.rememberKey("other-key"); // Dedup remains allowed.
    try std.testing.expectEqualStrings("[redacted]", try journal.safe(temp, "other-key"));
}
test "journal recursively redacts encoded JSON content without reformatting untouched text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const key = "nested-\"-\\-secret";
    var journal = try Journal.init(std.testing.allocator, &root, key);
    defer journal.deinit();
    var wiping = WipingAllocator{ .backing = std.testing.allocator };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const inner = try std.json.Stringify.valueAlloc(a, .{ .secret = key }, .{});
    const outer = try std.json.Stringify.valueAlloc(a, .{ .content = inner }, .{});
    const redacted = try journal.jsonText(a, outer);
    const result = try std.json.parseFromSlice(std.json.Value, a, redacted.text, .{});
    const content = try std.json.parseFromSlice(std.json.Value, a, result.value.object.get("content").?.string, .{});
    try std.testing.expectEqualStrings("[redacted]", content.value.object.get("secret").?.string);
    try std.testing.expect(!redacted.omitted and !redacted.truncated);
    const args = try journal.jsonValue(a, outer);
    const argument_content = try std.json.parseFromSlice(std.json.Value, a, args.value.object.get("content").?.string, .{});
    try std.testing.expectEqualStrings("[redacted]", argument_content.value.object.get("secret").?.string);
    const untouched = " { \"keep\": [1, true] } ";
    try std.testing.expectEqualStrings(untouched, (try journal.jsonText(a, untouched)).text);

    // 对象字段名也可以是完整的 JSON 字符串，不能只对值递归。
    var keyed: std.json.ObjectMap = .{};
    try keyed.put(a, inner, .{ .string = "value" });
    const keyed_input = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = keyed }, .{});
    const keyed_output = try journal.jsonValue(a, keyed_input);
    const decoded_key = try std.json.parseFromSlice(std.json.Value, a, keyed_output.value.object.keys()[0], .{});
    try std.testing.expectEqualStrings("[redacted]", decoded_key.value.object.get("secret").?.string);
    const collision = try std.fmt.allocPrint(a, "{{{s}:1,\"[redacted]\":2}}", .{try std.json.Stringify.valueAlloc(a, key, .{})});
    try std.testing.expectError(error.RedactedKeyCollision, journal.jsonValue(a, collision));
    try std.testing.expectError(error.DuplicateField, journal.jsonValue(a, "{\"x\":1,\"x\":2}"));
}
test "journal omits duplicated permission body and redacts JSON encoded call identifiers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-secret");
    defer journal.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content = "{\"secret\":\"fake\\u002dsecret\"}";
    const action = @import("../tools/tools.zig").Action{ .memory = .{ .action = .write, .topic = "core", .content = content } };
    const description = try action.description(a);
    const arguments = try std.json.Stringify.valueAlloc(a, action.memory, .{});
    const observer = journal.observer();
    observer.notify(.{ .submitted = "fixture" });
    observer.notify(.{ .event = .{ .assistant_committed = &.{.{ .tool_call = .{ .id = content, .name = "memory", .arguments = arguments } }} } });
    observer.notify(.{ .event = .{ .permission = .{ .id = 7, .tool_name = "memory", .description = description } } });
    observer.notify(.{ .decision = .{ .id = 7, .value = .deny } });
    observer.notify(.{ .tool_completed = .{ .call_id = content, .result = .{ .text = "User denied this action", .is_error = true } } });
    observer.notify(.{ .event = .{ .finished = .{ .status = .success } } });
    journal.flush();
    try std.testing.expectEqual(null, journal.failure());
    const file = try root.read(a, journal.store.path(), 0, record_limit);
    var lines = std.mem.splitScalar(u8, file.data, '\n');
    var permission_seen = false;
    var ids: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        const event = parsed.value.object.get("event").?.string;
        const data = parsed.value.object.get("data").?.object;
        if (std.mem.eql(u8, event, "permission")) {
            permission_seen = true;
            const saved = data.get("description").?.object;
            try std.testing.expect(saved.get("omitted").?.bool);
            try std.testing.expectEqualStrings(omitted, saved.get("text").?.string);
            try std.testing.expectEqual(description.len, @as(usize, @intCast(saved.get("source_bytes").?.integer)));
        }
        if (data.get("call_id")) |id| {
            ids += 1;
            const decoded = try std.json.parseFromSlice(std.json.Value, a, id.string, .{});
            try std.testing.expectEqualStrings("[redacted]", decoded.value.object.get("secret").?.string);
        }
    }
    try std.testing.expect(permission_seen);
    try std.testing.expectEqual(@as(usize, 2), ids);
}
test "journal growable records preserve envelope and propagate OOM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var wiping = WipingAllocator{ .backing = counted.allocator() };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    journal.began_ms = std.Io.Clock.awake.now(root.io).toMilliseconds();
    try journal.record(arena.allocator(), "state", .{ .state = r.State.calling_model });
    try journal.record(arena.allocator(), "usage", p.Usage{ .input_tokens = 123 });
    try std.testing.expect(counted.allocations > 0);

    const payload: [8192]u8 = @splat('x');
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, journal.record(failing.allocator(), "large", .{ .text = &payload }));
    try std.testing.expectEqual(@as(u64, 2), journal.seq);
    try journal.record(arena.allocator(), "large", .{ .text = &payload });
    try std.testing.expect(counted.allocated_bytes >= payload.len);
    journal.flush();
    try std.testing.expectEqual(null, journal.failure());
    const content = try root.read(std.testing.allocator, journal.store.path(), 0, record_limit);
    defer std.testing.allocator.free(content.data);
    var lines = std.mem.splitScalar(u8, content.data, '\n');
    var seq: i64 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        seq += 1;
        try std.testing.expectEqual(seq, parsed.value.object.get("seq").?.integer);
        if (seq == 3) try std.testing.expectEqualStrings(&payload, parsed.value.object.get("data").?.object.get("text").?.string);
    }
    try std.testing.expectEqual(@as(i64, 3), seq);
}
test "journal enqueue wakes idle consumer and finish wakes empty consumer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.observer().notify(.{ .submitted = "first" });
    journal.flush();
    for (0..16) |_| {
        try expectWriterWaiting(&journal);
        const previous = journal.seq;
        journal.observer().notify(.{ .event = .{ .state = .calling_model } });
        journal.flush();
        try std.testing.expectEqual(previous + 1, journal.seq);
    }
    try expectWriterWaiting(&journal);
    journal.finish();
    try std.testing.expectEqual(null, journal.failure());
    try std.testing.expect(journal.done and journal.worker == null);
    try std.testing.expectEqual(@as(usize, 0), journal.outstanding);
    try std.testing.expectEqual(@as(usize, 0), journal.bytes);
}
test "journal idle writer failure is visible and never accepts stranded records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var table = root.io.vtable.*;
    table.futexWait = canceledWriterWait;
    root.io.vtable = &table;
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.observer().notify(.{ .submitted = "fixture" });
    const start = std.Io.Clock.awake.now(std.testing.io);
    while (true) {
        journal.lock();
        const done = journal.done;
        journal.unlock();
        if (done) break;
        try std.testing.expect(start.untilNow(std.testing.io, .awake).toMilliseconds() < 1000);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
    try std.testing.expectEqual(error.Canceled, journal.failure().?);
    const seq = journal.seq;
    journal.observer().notify(.{ .event = .{ .finished = .{ .status = .success } } });
    try std.testing.expectEqual(seq, journal.seq);
    journal.flush();
    try std.testing.expect(journal.worker == null);
    try std.testing.expectEqual(@as(usize, 0), journal.outstanding);
}
test "steering is a redacted user record in the accepted turn, not a new submission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-steering-key");
    defer journal.deinit();
    const observer = journal.observer();
    observer.notify(.{ .submitted = "original task" });
    // Runtime's pre-model checkpoint republishes the direct input under id 0.
    observer.notify(.{ .event = .{ .user_committed = .{ .id = 0, .text = "original task" } } });
    observer.notify(.{ .event = .{ .user_committed = .{ .id = 77, .text = "adjust fake-steering-key" } } });
    observer.notify(.{ .event = .{ .permission_cleared = 9 } });
    observer.notify(.{ .event = .{ .finished = .{ .status = .success } } });
    journal.flush();
    try std.testing.expectEqual(null, journal.failure());
    const content = try root.read(std.testing.allocator, journal.store.path(), 0, record_limit);
    defer std.testing.allocator.free(content.data);
    try std.testing.expect(std.mem.indexOf(u8, content.data, "fake-steering-key") == null);
    var users: usize = 0;
    var direct = false;
    var steered = false;
    var cleared = false;
    var lines = std.mem.splitScalar(u8, content.data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqual(@as(i64, 1), obj.get("turn").?.integer);
        const event = obj.get("event").?.string;
        const data = obj.get("data").?.object;
        if (std.mem.eql(u8, event, "user")) {
            users += 1;
            if (data.get("delivery")) |delivery| {
                try std.testing.expectEqualStrings("steering", delivery.string);
                try std.testing.expectEqual(@as(i64, 77), data.get("input_id").?.integer);
                try std.testing.expectEqualStrings("adjust [redacted]", data.get("text").?.string);
                steered = true;
            } else {
                try std.testing.expect(data.get("input_id") == null);
                try std.testing.expectEqualStrings("original task", data.get("text").?.string);
                direct = true;
            }
        }
        if (std.mem.eql(u8, event, "permission_cleared")) {
            try std.testing.expectEqual(@as(i64, 9), data.get("id").?.integer);
            cleared = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), users);
    try std.testing.expect(direct and steered and cleared);
}
test "journal structured records redaction turns and first response" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    const key = "fake\"\\secret";
    var journal = try Journal.init(std.testing.allocator, &root, key);
    defer journal.deinit();
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    const fixed_id: [32]u8 = @splat('a');
    try journal.pinSessionID(fixed_id);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    const observer = journal.observer();
    observer.notify(.{ .submitted = "hello fake\"\\secret" });
    observer.notify(.{ .event = .{ .state = .calling_model } });
    observer.notify(.{ .event = .{ .text = "" } });
    observer.notify(.{ .event = .{ .reasoning = "NEVER_STORE_REASONING" } });
    observer.notify(.{ .event = .{ .text = "STREAM_ONLY" } });
    observer.notify(.{ .event = .{ .tool_preview = .{ .index = 0, .arguments = "NEVER_STORE_PREVIEW" } } });
    const blocks: []const p.Block = &.{
        .{ .text = "answer fake\"\\secret" },
        .{ .reasoning = "NEVER_STORE_REASONING" },
        .{ .tool_call = .{ .id = "call_1", .name = "read", .arguments = "{\"nested\":[\"fake\\\"\\\\secret\"],\"escaped\":\"fake\\u0022\\u005csecret\"}" } },
    };
    observer.notify(.{ .event = .{ .assistant_committed = blocks } });
    observer.notify(.{ .event = .{ .permission = .{ .id = 7, .tool_name = "read", .description = "read file" } } });
    observer.notify(.{ .decision = .{ .id = 7, .value = .allow_once } });
    observer.notify(.{ .event = .{ .tool_started = .{ .id = 7, .name = "read" } } });
    observer.notify(.{ .tool_completed = .{ .call_id = "call_1", .result = .{ .text = "{\"value\":\"fake\\u0022\\u005csecret\"}", .canceled = true } } });
    observer.notify(.{ .event = .{ .tool_result = .{ .id = 7, .name = "read", .result = .{ .text = "NEVER_DUPLICATE_BODY" } } } });
    var diagnostic: @import("../core/decision.zig").Diagnostic = .{
        .stage = .http,
        .backend = .systemone,
        .operation = .command,
        .http_status = 403,
    };
    diagnostic.setError(error.DecisionUnavailable);
    observer.notify(.{ .event = .{ .finished = .{
        .status = .failed,
        .detail = error.TestFailure,
        .http_status = 503,
        .decision_failure = diagnostic,
    } } });
    observer.notify(.{ .submitted = "second" });
    observer.notify(.{ .event = .{ .state = .compacting } });
    observer.notify(.{ .event = .{ .tool_preview = .{ .index = 0, .arguments = "hidden" } } });
    observer.notify(.{ .event = .{ .text = "hidden" } });
    observer.notify(.{ .event = .{ .finished = .{ .status = .success } } });
    journal.flush();
    try std.testing.expectEqual(null, journal.failure());
    try std.testing.expectError(error.SessionIDAlreadyStarted, journal.pinSessionID(fixed_id));
    try std.testing.expectEqualSlices(u8, &fixed_id, &journal.store.session_id);
    const content = try root.read(std.testing.allocator, journal.store.path(), 0, record_limit);
    defer std.testing.allocator.free(content.data);
    try std.testing.expect(std.mem.indexOf(u8, content.data, "\"session\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"") != null);
    for ([_][]const u8{ key, "fake", "NEVER_", "STREAM_ONLY" }) |secret| try std.testing.expect(std.mem.indexOf(u8, content.data, secret) == null);
    var lines = std.mem.splitScalar(u8, content.data, '\n');
    var seq: i64 = 0;
    var turn: i64 = 1;
    var first_count: usize = 0;
    var tool_count: usize = 0;
    var assistant_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        seq += 1;
        try std.testing.expectEqual(seq, obj.get("seq").?.integer);
        try std.testing.expectEqualStrings(&journal.store.session_id, obj.get("session").?.string);
        try std.testing.expectEqual(@as(i64, 1), obj.get("schema").?.integer);
        try std.testing.expect(obj.get("timestamp_ms").?.integer > 0);
        try std.testing.expect(obj.get("elapsed_ms").?.integer >= 0);
        const event = obj.get("event").?.string;
        const data = obj.get("data").?.object;
        if (std.mem.eql(u8, event, "user") and std.mem.eql(u8, data.get("text").?.string, "second")) turn = 2;
        try std.testing.expectEqual(turn, obj.get("turn").?.integer);
        if (std.mem.eql(u8, event, "first_response")) first_count += 1;
        if (std.mem.eql(u8, event, "permission") or std.mem.eql(u8, event, "decision")) {
            try std.testing.expectEqual(@as(i64, 7), data.get("id").?.integer);
            try std.testing.expect(data.get("host_id") == null);
        }
        if (std.mem.eql(u8, event, "assistant")) {
            assistant_count += 1;
            try std.testing.expectEqualStrings("answer [redacted]", data.get("text").?.string);
        }
        if (std.mem.eql(u8, event, "tool_call")) {
            const args = data.get("arguments").?.object;
            try std.testing.expectEqualStrings("[redacted]", args.get("nested").?.array.items[0].string);
            try std.testing.expectEqualStrings("[redacted]", args.get("escaped").?.string);
        }
        if (std.mem.eql(u8, event, "tool_result")) {
            tool_count += 1;
            try std.testing.expectEqualStrings("call_1", data.get("call_id").?.string);
            try std.testing.expect(data.get("canceled").?.bool);
            try std.testing.expectEqualStrings("{\"value\":\"[redacted]\"}", data.get("text").?.string);
        }
        if (std.mem.eql(u8, event, "finished") and turn == 1) {
            try std.testing.expectEqualStrings("TestFailure", data.get("detail").?.string);
            try std.testing.expectEqual(@as(i64, 503), data.get("http_status").?.integer);
            const diagnostic_fields = data.get("decision_failure").?.object;
            try std.testing.expectEqual(@as(u32, 7), diagnostic_fields.count());
            try std.testing.expectEqualStrings("http", diagnostic_fields.get("stage").?.string);
            try std.testing.expectEqualStrings("systemone", diagnostic_fields.get("backend").?.string);
            try std.testing.expectEqualStrings("command", diagnostic_fields.get("operation").?.string);
            try std.testing.expectEqualStrings("DecisionUnavailable", diagnostic_fields.get("cause").?.string);
            try std.testing.expectEqual(@as(i64, 403), diagnostic_fields.get("http_status").?.integer);
            try std.testing.expect(diagnostic_fields.get("transport_exit_code").? == .null);
            try std.testing.expect(diagnostic_fields.get("model_failure").? == .null);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), first_count);
    try std.testing.expectEqual(@as(usize, 1), tool_count);
    try std.testing.expectEqual(@as(usize, 1), assistant_count);
    try std.testing.expectEqual(@as(i64, 2), turn);
}
test "journal is lazy and storage failure is sticky" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.flush();
    try std.testing.expect(journal.worker == null);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    try root.dir.writeFile(std.testing.io, .{ .sub_path = ".thin", .data = "not a directory" });
    journal.observer().notify(.{ .submitted = "failure" });
    journal.flush();
    try std.testing.expect(journal.worker == null);
    const failure = journal.failure().?;
    journal.observer().notify(.{ .submitted = "still failed" });
    try std.testing.expectEqual(failure, journal.failure().?);
    try std.testing.expect(journal.seq <= 2);
    try std.testing.expectEqual(std.Io.File.Kind.file, (try root.dir.statFile(root.io, ".thin", .{})).kind);
}
test "journal text and encoded record size boundaries persist through store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    const payload = try std.testing.allocator.alloc(u8, text_limit + 1);
    defer std.testing.allocator.free(payload);
    @memset(payload, '"');
    @memset(payload[0 .. text_limit / 8], 1);
    const medium_len = 256 * 1024 + 1;
    const observer = journal.observer();
    observer.notify(.{ .submitted = payload[0..medium_len] });
    journal.flush();
    observer.notify(.{ .submitted = payload[0..text_limit] });
    journal.flush();
    observer.notify(.{ .submitted = payload });
    journal.flush();
    try std.testing.expectEqual(null, journal.failure());
    const content = try root.read(std.testing.allocator, journal.store.path(), 0, record_limit);
    defer std.testing.allocator.free(content.data);
    try std.testing.expect(!content.truncated);
    var lines = std.mem.splitScalar(u8, content.data, '\n');
    var users: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        if (!std.mem.eql(u8, obj.get("event").?.string, "user")) continue;
        users += 1;
        const data = obj.get("data").?.object;
        const expected = if (users == 1) payload[0..medium_len] else if (users == 2) payload[0..text_limit] else payload;
        try std.testing.expect(!data.get("omitted").?.bool);
        try std.testing.expectEqualSlices(u8, expected, data.get("text").?.string);
        if (users == 2) try std.testing.expect(line.len > 2 * 1024 * 1024);
    }
    try std.testing.expectEqual(@as(usize, 3), users);
}
test "journal bounded UTF8 payload and oversized encoded record continue" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "x");
    defer journal.deinit();
    const large = try std.testing.allocator.alloc(u8, text_limit + 2);
    defer std.testing.allocator.free(large);
    for (0..large.len / 3) |i| @memcpy(large[i * 3 ..][0..3], "中");
    journal.observer().notify(.{ .submitted = large });
    journal.observer().notify(.{ .tool_completed = .{ .call_id = "x", .result = .{ .text = large } } });
    // Each visible field is bounded, but JSON escaping can exceed the record cap.
    const control = try std.testing.allocator.alloc(u8, text_limit);
    defer std.testing.allocator.free(control);
    @memset(control, 1);
    journal.observer().notify(.{ .event = .{ .assistant_committed = &.{.{ .tool_call = .{ .id = control, .name = control, .arguments = "{}" } }} } });
    journal.observer().notify(.{ .event = .{ .finished = .{ .status = .success } } });
    journal.flush();
    try std.testing.expectEqual(null, journal.failure());
    const content = try root.read(std.testing.allocator, journal.store.path(), 0, record_limit);
    defer std.testing.allocator.free(content.data);
    try std.testing.expect(std.mem.indexOf(u8, content.data, "record_limit") == null);
    try std.testing.expect(std.mem.indexOf(u8, content.data, "\"event\":\"finished\"") != null);
    var lines = std.mem.splitScalar(u8, content.data, '\n');
    var large_record_seen = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(try std.json.validate(std.testing.allocator, line));
        if (line.len > 5 * 1024 * 1024) {
            const doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
            defer doc.deinit();
            const data = doc.value.object.get("data").?.object;
            try std.testing.expectEqualSlices(u8, control, data.get("call_id").?.string);
            try std.testing.expectEqualSlices(u8, control, data.get("name").?.string);
            large_record_seen = true;
        }
    }
    try std.testing.expect(large_record_seen);
}
test "journal nested omissions and real filesystem failure are explicit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    var wiping = WipingAllocator{ .backing = std.testing.allocator };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    var nested: [141]u8 = undefined;
    @memset(nested[0..70], '[');
    nested[70] = '0';
    @memset(nested[71..], ']');
    const json = try journal.jsonValue(arena.allocator(), &nested);
    try std.testing.expect(!json.dropped);
    const text = try journal.jsonText(arena.allocator(), &nested);
    try std.testing.expect(!text.omitted and !text.truncated);
    try std.testing.expectEqualStrings(&nested, text.text);
    const quoted = try journal.jsonText(arena.allocator(), "\"fake-key\"");
    try std.testing.expectEqualStrings("\"[redacted]\"", quoted.text);
    var numeric = try Journal.init(std.testing.allocator, &root, "1234567890");
    defer numeric.deinit();
    const number_text = try numeric.jsonText(arena.allocator(), "[1234567890,1]");
    try std.testing.expectEqualStrings("[\"[redacted]\",1]", number_text.text);
    try root.dir.writeFile(std.testing.io, .{ .sub_path = ".thin", .data = "not a directory" });
    journal.observer().notify(.{ .submitted = "not persisted" });
    journal.flush();
    try std.testing.expect(journal.failure() != null);
    const first_error = journal.failure().?;
    journal.observer().notify(.{ .event = .{ .finished = .{ .status = .success } } });
    try std.testing.expectEqual(first_error, journal.failure().?);
    try std.testing.expectEqualStrings("", journal.store.path());
}
test "memory diagnostic retains originating turn and drops on producer contention" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.test_stall.store(true, .release);
    defer journal.test_stall.store(false, .release);
    const observer_ = journal.observer();
    observer_.notify(.{ .submitted = "first" });
    var sink = journal.memoryDiagnosticSink();
    sink.memory_job_id = 42;
    observer_.notify(.{ .event = .{ .finished = .{ .status = .success } } });
    observer_.notify(.{ .submitted = "second" });
    sink.emit(.{ .stage = .memory_finalize });
    journal.lock();
    const item = journal.queue.items[journal.queue.items.len - 1].diagnostic;
    journal.unlock();
    try std.testing.expectEqual(@as(u64, 1), item.turn);
    try std.testing.expectEqual(@as(u64, 42), item.record.memory_job_id.?);
    try std.testing.expectEqual(sink.origin.?.began_ms, item.record.origin.?.began_ms);
    try std.testing.expect(item.elapsed_ms >= 0);
    sink.emit(.{ .stage = .memory_finalize });
    try std.testing.expectEqual(@as(u64, 0), journal.diagnostic_dropped.load(.monotonic));
    journal.diagnostic_span.store(std.math.maxInt(u64) - 1, .monotonic);
    try std.testing.expectEqual(std.math.maxInt(u64), sink.next());
    try std.testing.expectEqual(@as(u64, 0), sink.next());
    journal.test_stall.store(false, .release);
}
test "diagnostic admission is isolated and unstarted sink is inert" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    const sink = journal.diagnosticSink();
    try std.testing.expectEqual(@as(u64, 0), sink.next());
    sink.emit(.{ .stage = .checkpoint });
    try std.testing.expect(journal.worker == null and !journal.started);
    journal.test_stall.store(true, .release);
    journal.observer().notify(.{ .submitted = "test" });
    sink.emit(.{ .stage = .checkpoint });
    try std.testing.expectEqual(@as(u64, 0), journal.diagnostic_dropped.load(.monotonic));
    try std.testing.expectEqual(null, journal.failure());
    const before = journal.seq;
    journal.observer().notify(.{ .event = .{ .state = .calling_model } });
    try std.testing.expectEqual(before + 1, journal.seq);
    try std.testing.expectEqual(null, journal.failure());
    for (0..129) |_| sink.emit(.{ .stage = .checkpoint });
    try std.testing.expectEqual(@as(u64, 0), journal.diagnostic_dropped.load(.monotonic));
    journal.observer().notify(.{ .event = .{ .state = .calling_model } });
    try std.testing.expectEqual(null, journal.failure());
    journal.test_stall.store(false, .release);
    journal.finish();
}
test "memory evidence rejection journal point retains background origin" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(a, &root, "fake-key");
    defer journal.deinit();
    const observer_ = journal.observer();
    observer_.notify(.{ .submitted = "first" });
    var sink = journal.memoryDiagnosticSink();
    sink.memory_job_id = 42;
    observer_.notify(.{ .event = .{ .finished = .{ .status = .success } } });
    journal.flush();
    const path = try a.dupe(u8, journal.store.path());
    defer a.free(path);
    sink.emit(.{ .stage = .memory_request, .phase = .point, .span_id = 77, .result = .failed, .candidate_index = 1, .error_name = diagnostics.ErrorName.fromError(error.MemoryEvidenceSensitiveContent) });
    journal.flush();
    const content = try root.read(a, path, 0, record_limit);
    defer a.free(content.data);
    var lines = std.mem.splitScalar(u8, content.data, '\n');
    var found = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        defer parsed.deinit();
        const row = parsed.value.object;
        if (!std.mem.eql(u8, row.get("event").?.string, "diagnostic")) continue;
        const data = row.get("data").?.object;
        for ([_][]const u8{ "text", "content", "quote", "candidates" }) |key| {
            try std.testing.expect(row.get(key) == null);
            try std.testing.expect(data.get(key) == null);
        }
        try std.testing.expectEqual(@as(i64, 1), row.get("turn").?.integer);
        try std.testing.expectEqual(@as(i64, 1), data.get("origin_turn").?.integer);
        try std.testing.expectEqual(@as(i64, 42), data.get("memory_job_id").?.integer);
        try std.testing.expectEqual(@as(i64, 77), data.get("span_id").?.integer);
        try std.testing.expectEqual(@as(i64, 1), data.get("candidate_index").?.integer);
        try std.testing.expectEqualStrings("memory_request", data.get("stage").?.string);
        try std.testing.expectEqualStrings("point", data.get("phase").?.string);
        try std.testing.expectEqualStrings("failed", data.get("result").?.string);
        try std.testing.expectEqualStrings("MemoryEvidenceSensitiveContent", data.get("error_name").?.string);
        try std.testing.expect(!found);
        found = true;
    }
    try std.testing.expect(found);
}
test "diagnostic end preserves safe decision timeout cause" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.observer().notify(.{ .submitted = "test" });
    journal.flush();
    const path = try std.testing.allocator.dupe(u8, journal.store.path());
    defer std.testing.allocator.free(path);
    var failure: decision.Diagnostic = .{ .stage = .transport };
    failure.setError(error.Timeout);
    journal.diagnosticSink().emit(.{ .stage = .decision_request, .phase = .end, .result = .failed, .error_name = diagnostics.ErrorName.fromError(error.DecisionUnavailable), .decision_failure = failure });
    journal.flush();
    const content = try root.read(std.testing.allocator, path, 0, record_limit);
    defer std.testing.allocator.free(content.data);
    try std.testing.expect(std.mem.indexOf(u8, content.data, "\"event\":\"diagnostic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content.data, "\"error_name\":\"DecisionUnavailable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content.data, "\"cause\":\"Timeout\"") != null);
    var invalid = failure;
    invalid.cause[0] = ' ';
    try std.testing.expect(safeDiagnosticCause(&invalid) == null);
}
test "journal flush resumes and finish drains joins and rejects subsequent records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.observer().notify(.{ .submitted = "first" });
    journal.flush();
    try std.testing.expect(journal.worker != null);
    const path = try std.testing.allocator.dupe(u8, journal.store.path());
    defer std.testing.allocator.free(path);
    journal.observer().notify(.{ .event = .{ .finished = .{ .status = .success } } });
    journal.finish();
    journal.finish();
    try std.testing.expectEqual(null, journal.failure());
    try std.testing.expect(journal.done and journal.worker == null);
    try std.testing.expectEqual(@as(usize, 0), journal.bytes);
    const seq = journal.seq;
    try std.testing.expectEqual(seq, journal.seq);
    const content = try root.read(std.testing.allocator, path, 0, record_limit);
    defer std.testing.allocator.free(content.data);
    try std.testing.expect(std.mem.indexOf(u8, content.data, "\"event\":\"finished\"") != null);
}
test "journal stalled writer grows queue and finish cancels joins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.test_flush_timeout_ms = 20;
    journal.test_stall.store(true, .release);
    const observer = journal.observer();
    observer.notify(.{ .submitted = "queued without disk" });
    for (0..256) |_| observer.notify(.{ .event = .{ .state = .calling_model } });
    // All callbacks returned even though the writer cannot perform any I/O.
    // Observer is void: log failures/cancellation cannot replace this terminal.
    const terminal: r.Event = .{ .finished = .{ .status = .success } };
    observer.notify(.{ .event = terminal });
    try std.testing.expectEqual(.success, terminal.finished.status);
    try std.testing.expectEqual(null, journal.failure());
    try std.testing.expect(journal.seq > 256);
    journal.lock();
    const count = journal.outstanding;
    const bytes = journal.bytes;
    journal.unlock();
    try std.testing.expect(count > 128);
    try std.testing.expect(bytes > 0);
    try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    journal.finish();
    try std.testing.expectEqual(error.LogFlushTimeout, journal.failure().?);
    try std.testing.expect(journal.done and journal.worker == null);
    try std.testing.expectEqual(@as(usize, 0), journal.outstanding);
    try std.testing.expectEqual(@as(usize, 0), journal.bytes);
}
test "journal flush and finish timeouts cancel stalled writer without leaking" {
    inline for (.{ false, true }) |finishing| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root = try testRoot(tmp.dir);
        defer root.deinit();
        var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
        defer journal.deinit();
        journal.test_flush_timeout_ms = 20;
        journal.test_stall.store(true, .release);
        journal.observer().notify(.{ .submitted = "queued" });
        const began = std.Io.Clock.awake.now(root.io).toMilliseconds();
        if (finishing) journal.finish() else journal.flush();
        const elapsed = std.Io.Clock.awake.now(root.io).toMilliseconds() - began;
        try std.testing.expect(elapsed >= 20 and elapsed < 1000);
        try std.testing.expectEqual(error.LogFlushTimeout, journal.failure().?);
        try std.testing.expect(journal.done and journal.worker == null);
        try std.testing.expectEqual(@as(usize, 0), journal.bytes);
        journal.finish();
        try std.testing.expectError(error.FileNotFound, fs.openDirectory(root.dir.handle, ".thin"));
    }
}
test "journal expanded queue drains complete ordered records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    // Open only through the writer, then save the borrowed path while quiescent.
    journal.observer().notify(.{ .submitted = "first" });
    journal.flush();
    const path = try std.testing.allocator.dupe(u8, journal.store.path());
    defer std.testing.allocator.free(path);
    journal.test_stall.store(true, .release);
    // Allow one extra accepted record if the writer had already passed its
    // stall check; the next iteration observes the atomic stall.
    for (0..256) |_| {
        journal.observer().notify(.{ .event = .{ .state = .calling_model } });
    }
    try std.testing.expectEqual(null, journal.failure());
    const accepted = journal.seq;
    journal.test_stall.store(false, .release);
    journal.finish();
    try std.testing.expectEqual(null, journal.failure());
    try std.testing.expect(journal.worker == null and journal.done);
    const content = try root.read(std.testing.allocator, path, 0, record_limit);
    defer std.testing.allocator.free(content.data);
    var lines = std.mem.splitScalar(u8, content.data, '\n');
    var seq: u64 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        seq += 1;
        try std.testing.expectEqual(seq, @as(u64, @intCast(parsed.value.object.get("seq").?.integer)));
    }
    try std.testing.expectEqual(accepted, seq);
}
test "journal queue retains large popped inflight bytes and entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    // No writer: retain more than the old byte budget in flight.
    const data = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024 + 1);
    @memset(data, 0);
    try journal.enqueue(data);
    const inflight = journal.pop().?;
    const extra = try std.testing.allocator.dupe(u8, "{}");
    try journal.enqueue(extra);
    try std.testing.expectEqual(@as(usize, 2), journal.outstanding);
    journal.release(inflight);
    journal.release(journal.pop().?);
    try std.testing.expectEqual(@as(usize, 0), journal.bytes);
}
test "Memory closeout journal concurrent producers preserve origin sequences and drop accounting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    // Writer is stalled while the primary allocates; the auxiliary emits only
    // value records. After joining, no producer allocates alongside the writer.
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.test_stall.store(true, .release);
    defer journal.test_stall.store(false, .release);
    const observer_ = journal.observer();
    observer_.notify(.{ .submitted = "t1" });
    var old = journal.memoryDiagnosticSink();
    old.memory_job_id = 42;
    var other = old;
    other.memory_job_id = 43;
    const origin = old.origin.?;
    var producers: CloseoutProducers = .{ .journal = &journal, .sink = old };
    const thread = try std.Thread.spawn(.{}, CloseoutProducers.run, .{&producers});
    const drop_seen = CloseoutProducers.wait(&producers.dropped, root.io);
    // Both producers remain alive until both have finished their work.
    producers.go.store(true, .release);
    observer_.notify(.{ .submitted = "t2" });
    var primary_ids: [CloseoutProducers.n]u64 = undefined;
    var overlap_seen = false;
    for (&primary_ids, 0..) |*id, i| {
        id.* = other.next();
        other.emit(.{ .stage = .memory_finalize, .phase = .begin, .span_id = id.* });
        observer_.notify(.{ .event = .{ .state = .calling_model } });
        if (i == CloseoutProducers.n / 2) observer_.notify(.{ .submitted = "t3" });
        other.emit(.{ .stage = .memory_finalize, .phase = .end, .span_id = id.* });
        if (i == 0) {
            producers.primary_started.store(true, .release);
            overlap_seen = CloseoutProducers.wait(&producers.aux_started, root.io);
        }
    }
    producers.primary_done.store(true, .release);
    const aux_seen = CloseoutProducers.wait(&producers.aux_done, root.io);
    thread.join();
    try std.testing.expect(drop_seen and overlap_seen and aux_seen and producers.aux_ok);
    try std.testing.expectEqual(null, journal.failure());
    const forced_and_contention_drops = journal.diagnostic_dropped.load(.acquire);
    try std.testing.expectEqual(@as(u64, 0), forced_and_contention_drops);

    // With the worker stalled and both producers joined, this marker must be
    // accepted after turn 3 and provides a bounded check of origin timing.
    const before = std.Io.Clock.awake.now(root.io).toMilliseconds();
    const marker = old.next();
    old.emit(.{ .stage = .memory_finalize, .phase = .point, .span_id = marker });
    const after = std.Io.Clock.awake.now(root.io).toMilliseconds();
    observer_.notify(.{ .event = .{ .finished = .{ .status = .success } } });
    const final_dropped = journal.diagnostic_dropped.load(.acquire);
    try std.testing.expectEqual(forced_and_contention_drops, final_dropped);
    journal.test_stall.store(false, .release);
    journal.flush();
    try std.testing.expectEqual(null, journal.failure());
    const content = try root.read(std.testing.allocator, journal.store.path(), 0, record_limit);
    defer std.testing.allocator.free(content.data);
    journal.finish();

    var all_ids: [2 * CloseoutProducers.n + 1]u64 = undefined;
    @memcpy(all_ids[0..CloseoutProducers.n], &primary_ids);
    @memcpy(all_ids[CloseoutProducers.n .. 2 * CloseoutProducers.n], &producers.ids);
    all_ids[all_ids.len - 1] = marker;
    for (all_ids, 0..) |id, i| {
        try std.testing.expect(id > 0);
        for (all_ids[0..i]) |previous| try std.testing.expect(id != previous);
    }
    var phases: [2 * CloseoutProducers.n]u8 = @splat(0);
    var lines = std.mem.splitScalar(u8, content.data, '\n');
    var last_seq: i64 = 0;
    var last_dropped: i64 = 0;
    var diagnostic_count: u64 = 0;
    var saw_new_turn = false;
    var saw_marker = false;
    var saw_final = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const row = parsed.value.object;
        const seq = row.get("seq").?.integer;
        try std.testing.expect(seq > last_seq);
        last_seq = seq;
        const event = row.get("event").?.string;
        if (std.mem.eql(u8, event, "user") and row.get("turn").?.integer == 3) saw_new_turn = true;
        if (std.mem.eql(u8, event, "finished")) {
            const dropped = row.get("data").?.object.get("dropped_total").?.integer;
            try std.testing.expect(dropped >= last_dropped);
            try std.testing.expectEqual(final_dropped, @as(u64, @intCast(dropped)));
            last_dropped = dropped;
            saw_final = true;
        }
        if (!std.mem.eql(u8, event, "diagnostic")) continue;
        diagnostic_count += 1;
        const dropped = row.get("dropped_total").?.integer;
        try std.testing.expect(dropped >= last_dropped);
        last_dropped = dropped;
        const data = row.get("data").?.object;
        try std.testing.expectEqual(@as(i64, 1), row.get("turn").?.integer);
        try std.testing.expectEqual(@as(i64, 1), data.get("origin_turn").?.integer);
        const id: u64 = @intCast(data.get("span_id").?.integer);
        const job = data.get("memory_job_id").?.integer;
        if (id == marker) {
            try std.testing.expect(saw_new_turn);
            try std.testing.expectEqual(@as(i64, 42), job);
            try std.testing.expectEqualStrings("point", data.get("phase").?.string);
            const elapsed = row.get("elapsed_ms").?.integer;
            try std.testing.expect(elapsed >= @max(0, before -| origin.began_ms));
            try std.testing.expect(elapsed <= @max(0, after -| origin.began_ms));
            saw_marker = true;
        } else {
            var found = false;
            for (all_ids[0 .. all_ids.len - 1], 0..) |candidate, i| {
                if (id != candidate) continue;
                found = true;
                try std.testing.expectEqual(@as(i64, if (i < CloseoutProducers.n) 43 else 42), job);
                const phase = data.get("phase").?.string;
                const bit: u8 = if (std.mem.eql(u8, phase, "begin")) 1 else if (std.mem.eql(u8, phase, "end")) 2 else return error.UnexpectedPhase;
                try std.testing.expect(phases[i] & bit == 0);
                phases[i] |= bit;
                break;
            }
            try std.testing.expect(found);
        }
    }
    try std.testing.expect(saw_new_turn and saw_marker and saw_final);
    try std.testing.expectEqual(@as(u64, 2 * 2 * CloseoutProducers.n + 1), diagnostic_count + final_dropped);
}
test "deep JSON redaction is iterative and preserves full structure" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(a, &root, "deep-secret");
    defer journal.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const depth = 2048;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendNTimes(a, '[', depth);
    try source.appendSlice(a, "\"deep-secret\"");
    try source.appendNTimes(a, ']', depth);
    const result = try journal.jsonText(aa, source.items);
    try std.testing.expect(!result.omitted and !result.truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "deep-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "[redacted]") != null);
    try std.testing.expectEqual(depth * 2 + "\"[redacted]\"".len, result.text.len);
    try std.testing.expect(try std.json.validate(a, result.text));
    const args = try journal.jsonValue(aa, source.items);
    const encoded = try Journal.encodeJson(aa, args.value);
    try std.testing.expectEqualStrings(result.text, encoded);
    const observer = journal.observer();
    observer.notify(.{ .submitted = "deep fixture" });
    observer.notify(.{ .event = .{ .assistant_committed = &.{.{ .tool_call = .{ .id = "id", .name = "fixture", .arguments = source.items } }} } });
    journal.flush();
    try std.testing.expectEqual(null, journal.failure());
    const file = try root.read(a, journal.store.path(), 0, record_limit);
    defer a.free(file.data);
    try std.testing.expect(std.mem.indexOf(u8, file.data, "deep-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, file.data, "[redacted]") != null);
    var lines = std.mem.splitScalar(u8, file.data, '\n');
    while (lines.next()) |line| if (line.len != 0) try std.testing.expect(try std.json.validate(a, line));
}
test "contended diagnostic admission fails explicitly within deadline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var journal = try Journal.init(std.testing.allocator, &root, "fake-key");
    defer journal.deinit();
    journal.observer().notify(.{ .submitted = "fixture" });
    journal.flush();
    journal.test_flush_timeout_ms = 20;
    std.debug.assert(std.c.pthread_mutex_lock(&journal.producer_mutex) == .SUCCESS);
    const start = std.Io.Clock.awake.now(root.io);
    journal.diagnosticSink().emit(.{ .stage = .checkpoint });
    const elapsed = start.untilNow(root.io, .awake).toMilliseconds();
    std.debug.assert(std.c.pthread_mutex_unlock(&journal.producer_mutex) == .SUCCESS);
    try std.testing.expect(elapsed >= 20 and elapsed < 1000);
    try std.testing.expectEqual(error.LogProducerTimeout, journal.failure().?);
    try std.testing.expectEqual(@as(u64, 0), journal.diagnostic_dropped.load(.monotonic));
}
test "diagnostic allocation failure is reported rather than dropped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var journal = try Journal.init(failing.allocator(), &root, "fake-key");
    defer journal.deinit();
    journal.test_stall.store(true, .release);
    journal.test_flush_timeout_ms = 20;
    journal.observer().notify(.{ .submitted = "fixture" });
    try std.testing.expectEqual(null, journal.failure());
    failing.fail_index = failing.alloc_index;
    const sink = journal.diagnosticSink();
    for (0..256) |_| {
        if (journal.failure() != null) break;
        sink.emit(.{ .stage = .checkpoint });
    }
    try std.testing.expectEqual(error.OutOfMemory, journal.failure().?);
    try std.testing.expectEqual(@as(u64, 0), journal.diagnostic_dropped.load(.monotonic));
    journal.test_stall.store(false, .release);
    journal.finish();
}
test "journal allocation failure never escapes observer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root = try testRoot(tmp.dir);
    defer root.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var journal = try Journal.init(failing.allocator(), &root, "fake-key");
    defer journal.deinit();
    failing.fail_index = failing.alloc_index;
    journal.observer().notify(.{ .submitted = "accepted independently" });
    try std.testing.expectEqual(error.OutOfMemory, journal.failure().?);
    journal.observer().notify(.{ .event = .{ .finished = .{ .status = .success } } });
    try std.testing.expectEqual(@as(u64, 0), journal.seq);
}
