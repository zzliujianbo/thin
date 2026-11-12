test "grouped subagent progress snapshot encoder decoder roundtrip" {
    const a = std.testing.allocator;
    const rows = [_]@import("../core/subagent_status.zig").AgentView{
        .{ .id = 1, .phase = .running },   .{ .id = 2, .phase = .waiting },
        .{ .id = 3, .phase = .completed }, .{ .id = 7, .phase = .failed },
    };
    var expected: @import("../core/subagent_status.zig").View = .{ .group_id = 42, .revision = 3, .total = 4, .running = 1, .waiting = 1, .completed = 1, .failed = 1, .elapsed_ms = 99, .latest_id = 7, .agents = &rows };
    const text = "working 中文";
    expected.text_len = text.len;
    @memcpy(expected.text_buf[0..text.len], text);
    var out = protocol.Out.init(a);
    defer out.deinit();
    try out.ok(1);
    try protocol.encodeSnapshot(&out, .{ .session = @splat('a'), .project = "/tmp", .owner = .daemon, .subagents_supported = true, .subagents = expected });
    const bytes = try out.finish();
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    var decoded = try decodeSubagentView(a, parsed.value.object.get("snapshot").?.object.get("subagents").?);
    parsed.deinit();
    defer decoded.deinitOwned(a);
    try std.testing.expect(@import("../core/subagent_status.zig").View.eql(expected, decoded));

    var old = protocol.Out.init(a);
    defer old.deinit();
    try old.ok(2);
    try protocol.encodeSnapshot(&old, .{ .session = @splat('b'), .project = "/tmp", .owner = .daemon });
    const old_bytes = try old.finish();
    defer a.free(old_bytes);
    const old_parsed = try std.json.parseFromSlice(std.json.Value, a, old_bytes, .{});
    defer old_parsed.deinit();
    try std.testing.expect(old_parsed.value.object.get("snapshot").?.object.get("subagents") == null);
}
test "per-agent status rows survive wire document and owned clone" {
    const a = std.testing.allocator;
    var rows = [_]@import("../core/subagent_status.zig").AgentView{
        .{ .id = 1, .revision = 1, .phase = .starting, .elapsed_ms = 10 },
        .{ .id = 2, .revision = 2, .phase = .waiting, .elapsed_ms = 20 },
        .{ .id = 3, .revision = 3, .phase = .completed, .elapsed_ms = 30 },
        .{ .id = 4, .revision = 4, .phase = .failed, .elapsed_ms = 40 },
    };
    for (&rows, [_][]const u8{ "one", "two", "three", "four" }) |*row, text| {
        row.text_len = @intCast(text.len);
        @memcpy(row.text_buf[0..text.len], text);
    }
    const original: @import("../core/subagent_status.zig").View = .{ .agents = &rows, .group_id = 1, .revision = 4, .total = 4, .running = 1, .waiting = 1, .completed = 1, .failed = 1, .latest_id = 4 };
    var out = protocol.Out.init(a);
    defer out.deinit();
    try out.ok(1);
    try protocol.encodeSubagentView(&out, original);
    const bytes = try out.finish();
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    var decoded = try decodeSubagentView(a, parsed.value.object.get("subagents").?);
    parsed.deinit();
    defer decoded.deinitOwned(a);
    try std.testing.expect(@import("../core/subagent_status.zig").View.eql(original, decoded));
    var projection = try decoded.clone(a);
    defer projection.deinitOwned(a);
    decoded.deinitOwned(a);
    try std.testing.expectEqualStrings("four", projection.agents[3].latestText());
    try std.testing.expectEqual(@as(u64, 20), projection.agents[1].elapsed_ms);
    try std.testing.expectEqual(@import("../core/subagent_status.zig").Phase.waiting, projection.agents[1].phase);
}
test "per-agent status rows reject malformed wire and missing agents" {
    const a = std.testing.allocator;
    const prefix = "{\"group_id\":1,\"revision\":2,\"total\":2,\"running\":1,\"waiting\":1,\"completed\":0,\"failed\":0,\"canceled\":0,\"paused\":0,\"elapsed_ms\":3,\"latest_id\":9,\"text\":\"working\"";
    const suffixes = [_][]const u8{
        ",\"agents\":[{\"id\":1,\"revision\":1,\"phase\":\"bogus\",\"elapsed_ms\":1,\"text\":\"x\"},{\"id\":2,\"revision\":1,\"phase\":\"waiting\",\"elapsed_ms\":2,\"text\":\"y\"}]}",
        ",\"agents\":[{\"id\":1,\"revision\":1,\"phase\":\"running\",\"elapsed_ms\":1,\"text\":\"x\"},{\"id\":1,\"revision\":1,\"phase\":\"waiting\",\"elapsed_ms\":2,\"text\":\"y\"}]}",
        ",\"agents\":[{\"id\":1,\"revision\":1,\"phase\":\"running\",\"elapsed_ms\":1,\"text\":\"\\n\"},{\"id\":2,\"revision\":1,\"phase\":\"waiting\",\"elapsed_ms\":2,\"text\":\"y\"}]}",
        ",\"agents\":[{\"id\":1,\"revision\":1,\"phase\":\"running\",\"elapsed_ms\":1,\"text\":\"x\"},{\"id\":2,\"revision\":1,\"phase\":\"running\",\"elapsed_ms\":2,\"text\":\"y\"}]}",
        ",\"agents\":[{\"id\":1,\"revision\":1,\"phase\":\"running\",\"elapsed_ms\":-1,\"text\":\"x\"},{\"id\":2,\"revision\":1,\"phase\":\"waiting\",\"elapsed_ms\":2,\"text\":\"y\"}]}",
    };
    for (suffixes) |suffix| {
        const bytes = try std.mem.concat(a, u8, &.{ prefix, suffix });
        defer a.free(bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.ProtocolError, decodeSubagentView(a, parsed.value));
    }
    const legacy = try std.mem.concat(a, u8, &.{ prefix, "}" });
    defer a.free(legacy);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, legacy, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.ProtocolError, decodeSubagentView(a, parsed.value));
}
test "grouped subagent progress decoder owns text and rejects malformed counts" {
    const a = std.testing.allocator;
    const bytes = "{\"group_id\":1,\"revision\":2,\"total\":2,\"running\":1,\"waiting\":1,\"completed\":0,\"failed\":0,\"canceled\":0,\"paused\":0,\"elapsed_ms\":3,\"latest_id\":9,\"text\":\"working\",\"agents\":[{\"id\":1,\"revision\":1,\"phase\":\"running\",\"elapsed_ms\":1,\"text\":\"x\"},{\"id\":9,\"revision\":1,\"phase\":\"waiting\",\"elapsed_ms\":2,\"text\":\"y\"}]}";
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    var view = try decodeSubagentView(a, parsed.value);
    parsed.deinit();
    defer view.deinitOwned(a);
    try std.testing.expectEqualStrings("working", view.latestText());
    const invalid = "{\"group_id\":1,\"revision\":2,\"total\":1,\"running\":1,\"waiting\":1,\"completed\":0,\"failed\":0,\"canceled\":0,\"paused\":0,\"elapsed_ms\":3,\"latest_id\":9,\"text\":\"working\",\"agents\":[{\"id\":1,\"revision\":1,\"phase\":\"running\",\"elapsed_ms\":1,\"text\":\"x\"}]}";
    const bad = try std.json.parseFromSlice(std.json.Value, a, invalid, .{});
    defer bad.deinit();
    try std.testing.expectError(error.ProtocolError, decodeSubagentView(a, bad.value));
}
test "background view decoder requires exact bounded count" {
    const a = std.testing.allocator;
    const valid = try std.json.parseFromSlice(std.json.Value, a, "{\"active_count\":2}", .{});
    defer valid.deinit();
    try std.testing.expectEqual(@as(usize, 2), (try decodeBackgroundView(valid.value)).active_count);
    for ([_][]const u8{ "{}", "{\"active_count\":null}", "{\"active_count\":-1}", "{\"active_count\":1.0}", "{\"active_count\":1,\"extra\":0}" }) |json| {
        const invalid = try std.json.parseFromSlice(std.json.Value, a, json, .{});
        defer invalid.deinit();
        try std.testing.expectError(error.ProtocolError, decodeBackgroundView(invalid.value));
    }
}
test "memory summary wire roundtrip and strict bounds" {
    const a = std.testing.allocator;
    var view: memory_status.View = .{ .enabled = true, .last_terminal = .{ .id = 4, .result = .saved, .saved_count = 2 } };
    view.last_terminal.?.summary.append("中文\n记忆");
    var out = protocol.Out.init(a);
    defer out.deinit();
    try out.ok(1);
    try protocol.encodeMemoryView(&out, view);
    const bytes = try out.finish();
    defer a.free(bytes);
    var doc = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer doc.deinit();
    const decoded = try decodeMemoryView(doc.value.object.get("memory").?);
    try std.testing.expect(std.meta.eql(view, decoded));
    const invalid = [_][]const u8{
        "{\"enabled\":true,\"revision\":0,\"queued_count\":0,\"active\":null,\"last_terminal\":{\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":42}}",
        "{\"enabled\":true,\"revision\":0,\"queued_count\":0,\"active\":null,\"last_terminal\":{\"id\":1,\"result\":\"saved\",\"failure\":null,\"summary\":\"\"}}",
        "{\"enabled\":true,\"revision\":0,\"queued_count\":0,\"active\":null,\"last_terminal\":{\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":0}}",
        "{\"enabled\":true,\"revision\":0,\"queued_count\":0,\"active\":null,\"last_terminal\":{\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":4294967296,\"summary\":\"\"}}",
        "{\"enabled\":true,\"revision\":0,\"queued_count\":0,\"active\":null,\"last_terminal\":{\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":\"bad\\u001b\"}}",
    };
    for (invalid) |text| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.ProtocolError, decodeMemoryView(parsed.value));
    }
    const long: [257]u8 = @splat('x');
    const oversized = try std.fmt.allocPrint(a, "{{\"enabled\":true,\"revision\":0,\"queued_count\":0,\"active\":null,\"last_terminal\":{{\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":\"{s}\"}}}}", .{&long});
    defer a.free(oversized);
    var large = try std.json.parseFromSlice(std.json.Value, a, oversized, .{});
    defer large.deinit();
    try std.testing.expectError(error.ProtocolError, decodeMemoryView(large.value));
}
test "memory view decoder rejects malformed fields" {
    const a = std.testing.allocator;
    const valid = "{\"enabled\":true,\"revision\":2,\"queued_count\":1,\"active\":{\"id\":7,\"phase\":\"saving\"},\"last_terminal\":{\"id\":6,\"result\":\"failed\",\"failure\":\"storage\",\"saved_count\":0,\"summary\":\"\"}}";
    var doc = try std.json.parseFromSlice(std.json.Value, a, valid, .{});
    defer doc.deinit();
    const view = try decodeMemoryView(doc.value);
    try std.testing.expectEqual(memory_status.Phase.saving, view.active.?.phase);
    try std.testing.expectEqual(memory_status.Failure.storage, view.last_terminal.?.failure.?);
    const invalid = "{\"enabled\":true,\"revision\":2,\"queued_count\":1,\"active\":{\"id\":7,\"phase\":\"arbitrary prose\"},\"last_terminal\":null}";
    var bad = try std.json.parseFromSlice(std.json.Value, a, invalid, .{});
    defer bad.deinit();
    try std.testing.expectError(error.ProtocolError, decodeMemoryView(bad.value));
}
test "response parsing propagates allocation failures" {
    const Helper = struct {
        fn parse(a: std.mem.Allocator) !void {
            var response = try parseObject(a,
                \\{"id":1,"ok":true,"data":{"nested":{"name":"value"},"items":[{"key":"value"},2]}}
            );
            defer response.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Helper.parse, .{});
}
test "response integers preserve u64 and reject coercion without trapping" {
    var response = try parseObject(std.testing.allocator,
        \\{"id":18446744073709551615,"large":9223372036854775808,"zero":0,"negative":-1,"fraction":1.5,"float":1.0,"exponent":1e3,"string":"1","overflow":18446744073709551616}
    );
    defer response.deinit();
    try std.testing.expectEqual(std.math.maxInt(u64), response.uint("id").?);
    try std.testing.expectEqual(@as(u64, 9223372036854775808), response.uint("large").?);
    try std.testing.expectEqual(@as(u64, 0), response.uint("zero").?);
    for ([_][]const u8{ "negative", "fraction", "float", "exponent", "string", "overflow" }) |field| {
        try std.testing.expect(response.uint(field) == null);
    }
}
test "communication delivers real stream frames during a delayed control reply and joins promptly" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var directory = try unix.Directory.resolveUnder(a, path[0..n], "rt", @intCast(std.c.getuid()));
    defer directory.deinit();
    var listener = try unix.Listener.bind(a, &directory, "watch.sock", .{});
    defer listener.deinit();
    var pair = try pairOf(a);
    defer pair.deinit();
    pair.client.stream = try StreamReceiver.start(a, io, listener.path, pair.client.uid, 5);
    pair.client.stream_expected = true;
    pair.client.need_history = true;
    pair.client.dirty = false; // This fixture tests control waiting, not initial settings refresh.
    var frontend: ?*@import("frontend.zig").Frontend = try @import("frontend.zig").Frontend.start(pair.client);
    defer if (frontend) |live| live.deinit();
    const connection = frontend.?.connection();
    const actions = connection.async_actions.?;
    const ticket = try actions.start(5, .cancel);
    var stream = try listener.accept(.{ .io = io, .timeout_ms = 2000 });
    defer stream.close();
    const watch_bytes = (try stream.readFrame(.{ .io = io, .timeout_ms = 2000 })) orelse return error.MissingWatch;
    defer a.free(watch_bytes);
    var watch = try protocol.parseRequest(a, watch_bytes);
    defer watch.deinit();
    try testing.expectEqual(protocol.Op.watch, watch.op);

    // No response is sent yet. Depending on scheduling, the first control RPC
    // is either the eager metadata probe or our cancel; both must leave stream
    // parsing/publication and UI-local callbacks responsive.
    const request_bytes = (try pair.server.readFrame(.{ .io = io, .timeout_ms = 2000 })).?;
    defer a.free(request_bytes);
    var request_ = try protocol.parseRequest(a, request_bytes);
    defer request_.deinit();
    try testing.expect(request_.op == .cancel or request_.op == .poll_metadata);
    try stream.writeFrame("{\"v\":5,\"id\":1,\"ok\":true,\"epoch\":5,\"stream\":\"snapshot\",\"through\":0,\"snapshot\":{\"background\":{\"active_count\":0},\"epoch\":5,\"attached\":true,\"busy\":true,\"phase\":\"calling_model\",\"task\":1,\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}}", .{ .io = io, .timeout_ms = 2000 });
    try stream.writeFrame("{\"v\":5,\"id\":1,\"ok\":true,\"epoch\":5,\"stream\":\"baseline\",\"base\":0,\"through\":0,\"entries\":[]}", .{ .io = io, .timeout_ms = 2000 });
    const event_bytes = try protocol.encodeEvent(a, .{ .text = "delayed-control-live-body" });
    defer a.free(event_bytes);
    // Mandatory wire sequence: the page entry carries the owner's position.
    const sequenced = try std.fmt.allocPrint(a, "{s},\"seq\":1}}", .{event_bytes[0 .. event_bytes.len - 1]});
    defer a.free(sequenced);
    const page = try std.fmt.allocPrint(a, "{{\"v\":5,\"id\":1,\"ok\":true,\"epoch\":5,\"stream\":\"events\",\"from\":0,\"through\":1,\"events\":[{s}]}}", .{sequenced});
    defer a.free(page);
    try stream.writeFrame(page, .{ .io = io, .timeout_ms = 2000 });
    const deadline = std.Io.Clock.awake.now(io);
    var received = false;
    while (deadline.untilNow(io, .awake).toMilliseconds() < 1500) {
        const before = std.Io.Clock.awake.now(io);
        if (try connection.session_client.?.poll(a)) |owned| {
            var item = owned;
            defer item.deinit();
            try testing.expectEqualStrings("delayed-control-live-body", item.event.text);
            received = true;
        }
        try testing.expect(before.untilNow(io, .awake).toMilliseconds() < 200);
        if (received) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try testing.expect(received); // This assertion precedes the delayed reply.
    try testing.expect(actions.poll() == null); // Admission was not success.
    try expectNoFrameOn(&pair.server); // Stream progress issued no nested RPC.
    try pair.reply(request_.id, "\"changed\":false");
    if (request_.op == .poll_metadata) {
        const cancel_bytes = (try pair.server.readFrame(.{ .io = io, .timeout_ms = 2000 })).?;
        defer a.free(cancel_bytes);
        var command = try protocol.parseRequest(a, cancel_bytes);
        defer command.deinit();
        try testing.expectEqual(protocol.Op.cancel, command.op);
        try pair.reply(command.id, "\"accepted\":true");
    }
    const completed_at = std.Io.Clock.awake.now(io);
    var completed = false;
    while (completed_at.untilNow(io, .awake).toMilliseconds() < 2000) {
        if (actions.poll()) |owned| {
            var result = owned;
            defer result.deinit();
            try testing.expectEqual(ticket, result.request.ticket);
            try testing.expect(result.failure == null);
            completed = true;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try testing.expect(completed);
    const stopped_at = std.Io.Clock.awake.now(io);
    frontend.?.deinit();
    frontend = null;
    try testing.expect(stopped_at.untilNow(io, .awake).toMilliseconds() < 1000);
}
test "frontend ACK rides the bound watch socket, coalesces and resumes without a baseline reset" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var dir = try unix.Directory.resolveUnder(a, path[0..n], "ackloop", @intCast(std.c.getuid()));
    defer dir.deinit();
    var listener = try unix.Listener.bind(a, &dir, "watch.sock", .{});
    defer listener.deinit();
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.stream = try StreamReceiver.start(a, io, listener.path, client.uid, 5);
    client.stream_expected = true;
    client.need_history = true;
    client.dirty = false;
    var frontend: ?*@import("frontend.zig").Frontend = try @import("frontend.zig").Frontend.start(client);
    defer if (frontend) |live| live.deinit();
    const connection = frontend.?.connection();
    const ui = connection.session_client.?;

    // Fresh viewer: no resume cursor, snapshot then baseline for the same
    // display watermark.
    var watch = try listener.accept(.{ .io = io, .timeout_ms = 2_000 });
    const raw_watch = (try watch.readFrame(.{ .io = io, .timeout_ms = 2_000 })).?;
    defer a.free(raw_watch);
    var watch_request = try protocol.parseRequest(a, raw_watch);
    defer watch_request.deinit();
    try testing.expectEqual(protocol.Op.watch, watch_request.op);
    try testing.expect((try watch_request.optionalU64("since")) == null);
    try watch.writeFrame("{\"v\":5,\"id\":1,\"ok\":true,\"epoch\":5,\"through\":0,\"stream\":\"snapshot\",\"snapshot\":{\"background\":{\"active_count\":0},\"epoch\":5,\"attached\":true,\"busy\":true,\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}}", .{ .io = io, .timeout_ms = 2_000 });
    try watch.writeFrame("{\"v\":5,\"id\":1,\"ok\":true,\"epoch\":5,\"stream\":\"baseline\",\"base\":0,\"through\":0,\"entries\":[]}", .{ .io = io, .timeout_ms = 2_000 });

    const first_page = try readyPage(a, 0, 1, &.{1}, "a");
    defer a.free(first_page);
    try watch.writeFrame(first_page, .{ .io = io, .timeout_ms = 2_000 });

    // Poll through the real Frontend and acknowledge through the vtable: the
    // UI thread only admits; the receiver performs the wire write.
    var first: ?session_client.Item = null;
    const first_deadline = std.Io.Clock.awake.now(io);
    while (first_deadline.untilNow(io, .awake).toMilliseconds() < 2_000) {
        if (try ui.poll(a)) |item| {
            first = item;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    defer if (first) |*item| item.deinit();
    try testing.expectEqualStrings("a", first.?.event.text);
    try testing.expectEqual(@as(u64, 1), first.?.delivery_sequence);
    try testing.expectEqual(@as(u64, 5), first.?.delivery_epoch);
    // A non-live watermark is a no-op; a superseded epoch is refused instead of
    // being recorded against this stream.
    try ui.acknowledge(5, 0);
    try testing.expectError(error.StaleControl, ui.acknowledge(4, 1));
    try ui.acknowledge(5, 1);
    const first_ack = (try readWatchFrame(&watch, a)).ack;
    try testing.expectEqual(@as(u64, 1), first_ack.sequence);
    try ackReply(&watch, a, first_ack.id, 5, first_ack.first, first_ack.sequence, 1, true);
    const confirm_deadline = std.Io.Clock.awake.now(io);
    while (confirm_deadline.untilNow(io, .awake).toMilliseconds() < 2_000) {
        if (client.stream.?.ackState().confirmed_through == 1) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(u64, 1), client.stream.?.ackState().confirmed_through);

    // Two newer admissions while one ACK is outstanding collapse to the latest:
    // no per-event FIFO reaches the owner.
    // UTF-8 plus a CR-bearing delta: the CR boundary must stay a separate
    // unacknowledged item across the reconnect, never absorbed into the other.
    const second_page = try std.fmt.allocPrint(a, "{{\"v\":5,\"id\":1,\"ok\":true,\"epoch\":5,\"stream\":\"events\",\"from\":1,\"through\":3,\"events\":[{{\"t\":\"text\",\"v\":\"中\",\"seq\":2}},{{\"t\":\"text\",\"v\":\"\\r\",\"seq\":3}}]}}", .{});
    defer a.free(second_page);
    try watch.writeFrame(second_page, .{ .io = io, .timeout_ms = 2_000 });
    var received: usize = 0;
    const second_deadline = std.Io.Clock.awake.now(io);
    while (second_deadline.untilNow(io, .awake).toMilliseconds() < 2_000 and received < 2) {
        if (try ui.poll(a)) |item| {
            var owned = item;
            defer owned.deinit();
            received += 1;
            try testing.expectEqual(@as(u64, @intCast(received + 1)), owned.delivery_sequence);
            try testing.expectEqual(owned.delivery_sequence, owned.delivery_first_sequence);
            try testing.expect(!owned.history_replay and !owned.history_reset);
            if (received == 1) {
                try testing.expectEqualStrings("中", owned.event.text);
            } else {
                try testing.expectEqualStrings("\r", owned.event.text);
            }
        } else try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(usize, 2), received);
    try ui.acknowledge(5, 3);
    const pending_ack = (try readWatchFrame(&watch, a)).ack;
    try testing.expectEqual(@as(u64, 3), pending_ack.sequence);
    // A later independent range is admitted but stays queued behind the one
    // outstanding frame; it is never widened into a cumulative watermark.
    try ui.acknowledgeRange(5, 20, 30);
    var quiet = [_]std.c.pollfd{.{ .fd = watch.fd, .events = std.c.POLL.IN, .revents = 0 }};
    try testing.expectEqual(@as(c_int, 0), std.c.poll(&quiet, 1, 40));
    // A cancel is serviced while one ACK is outstanding and another range is
    // queued: the watch duplex never owns or pauses the control connection.
    const ticket = try connection.async_actions.?.start(5, .cancel);
    try serveControlUntilCancel(&pair, a);
    const cancel_deadline = std.Io.Clock.awake.now(io);
    var canceled = false;
    while (cancel_deadline.untilNow(io, .awake).toMilliseconds() < 2_000) {
        if (connection.async_actions.?.poll()) |completion| {
            var owned = completion;
            defer owned.deinit();
            try testing.expectEqual(ticket, owned.request.ticket);
            try testing.expect(owned.failure == null);
            canceled = true;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try testing.expect(canceled);
    // The pending proofs are untouched by the control operation.
    try testing.expectEqual(@as(usize, 2), client.stream.?.ackState().pending);
    // The unconfirmed proof survives a socket failure.
    watch.close();

    // The stream dies; recovery reads the control socket (never resubmits) and
    // resumes the SAME viewer from its own cursor.
    try serveControlUntilSnapshot(&pair, a);
    var resumed = try listener.accept(.{ .io = io, .timeout_ms = 2_000 });
    defer resumed.close();
    const raw_resume = (try resumed.readFrame(.{ .io = io, .timeout_ms = 2_000 })).?;
    defer a.free(raw_resume);
    var request = try protocol.parseRequest(a, raw_resume);
    defer request.deinit();
    try testing.expectEqual(protocol.Op.watch, request.op);
    try testing.expectEqual(@as(u64, 3), try request.u64Field("since"));
    // ... and its pending prefix is resent idempotently on the new connection,
    // followed by the exact selective range that was still queued.
    const resent = (try readWatchFrame(&resumed, a)).ack;
    try testing.expectEqual(@as(u64, 0), resent.first);
    try testing.expectEqual(@as(u64, 3), resent.sequence);
    try ackReply(&resumed, a, resent.id, 5, resent.first, resent.sequence, 3, true);
    const selective = (try readWatchFrame(&resumed, a)).ack;
    try testing.expectEqual(@as(u64, 20), selective.first);
    try testing.expectEqual(@as(u64, 30), selective.sequence);
    try ackReply(&resumed, a, selective.id, 5, selective.first, selective.sequence, 3, true);
    const settled = std.Io.Clock.awake.now(io);
    while (settled.untilNow(io, .awake).toMilliseconds() < 2_000) {
        if (client.stream.?.ackState().pending == 0) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(usize, 0), client.stream.?.ackState().pending);

    // Same viewer: snapshot at the cursor is redundant, the delta continues the
    // owned stream with no synthetic history reset and no duplicate.
    try resumed.writeFrame("{\"v\":5,\"id\":1,\"ok\":true,\"epoch\":5,\"through\":3,\"stream\":\"snapshot\",\"snapshot\":{\"background\":{\"active_count\":0},\"epoch\":5,\"attached\":true,\"busy\":true,\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}}", .{ .io = io, .timeout_ms = 2_000 });
    const delta = try readyPage(a, 3, 4, &.{4}, "d");
    defer a.free(delta);
    try resumed.writeFrame(delta, .{ .io = io, .timeout_ms = 2_000 });
    var last: ?session_client.Item = null;
    const last_deadline = std.Io.Clock.awake.now(io);
    while (last_deadline.untilNow(io, .awake).toMilliseconds() < 2_000) {
        if (try ui.poll(a)) |item| {
            last = item;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    defer if (last) |*item| item.deinit();
    try testing.expectEqualStrings("d", last.?.event.text);
    try testing.expectEqual(@as(u64, 4), last.?.delivery_sequence);
    try testing.expect(!last.?.history_replay and !last.?.history_reset);
    try testing.expectEqual(@as(u64, 4), client.cursor);
}
test "new viewer baseline rows precede ordered pages and gaps are surfaced" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var dir = try unix.Directory.resolveUnder(a, path[0..n], "baseline", @intCast(std.c.getuid()));
    defer dir.deinit();
    var listener = try unix.Listener.bind(a, &dir, "watch.sock", .{});
    defer listener.deinit();
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.stream = try StreamReceiver.start(a, io, listener.path, client.uid, 5);
    client.stream_expected = true;
    client.need_history = true;
    client.dirty = false;
    var frontend: ?*@import("frontend.zig").Frontend = try @import("frontend.zig").Frontend.start(client);
    defer if (frontend) |live| live.deinit();
    const connection = frontend.?.connection();
    const ui = connection.session_client.?;

    var watch = try listener.accept(.{ .io = io, .timeout_ms = 2_000 });
    defer watch.close();
    const raw_watch = (try watch.readFrame(.{ .io = io, .timeout_ms = 2_000 })).?;
    defer a.free(raw_watch);
    var watch_request = try protocol.parseRequest(a, raw_watch);
    defer watch_request.deinit();
    try testing.expectEqual(protocol.Op.watch, watch_request.op);
    const hello = try protocol.encodeEvent(a, .{ .user_committed = .{ .id = 1, .text = "hello" } });
    defer a.free(hello);
    try watch.writeFrame("{\"v\":5,\"id\":1,\"ok\":true,\"epoch\":5,\"through\":5,\"stream\":\"snapshot\",\"snapshot\":{\"background\":{\"active_count\":0},\"epoch\":5,\"attached\":true,\"busy\":true,\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}}", .{ .io = io, .timeout_ms = 2_000 });
    const baseline = try std.fmt.allocPrint(a, "{{\"v\":5,\"id\":1,\"ok\":true,\"epoch\":5,\"stream\":\"baseline\",\"base\":2,\"through\":2,\"truncated\":false,\"entries\":[{s}]}}", .{hello});
    defer a.free(baseline);
    try watch.writeFrame(baseline, .{ .io = io, .timeout_ms = 2_000 });

    var first: ?session_client.Item = null;
    const baseline_deadline = std.Io.Clock.awake.now(io);
    while (baseline_deadline.untilNow(io, .awake).toMilliseconds() < 2_000) {
        if (try ui.poll(a)) |item| {
            first = item;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    defer if (first) |*item| item.deinit();
    try testing.expect(first.?.history_replay and first.?.history_reset);
    try testing.expectEqualStrings("hello", first.?.event.user_committed.text);
    try testing.expectEqual(@as(u64, 0), first.?.delivery_sequence);

    // Positions 4 and 5 follow the baseline cutoff; position 3 is gone (a
    // selectively retired control event), so the page must say so.
    const page = try std.fmt.allocPrint(a, "{{\"v\":5,\"id\":1,\"ok\":true,\"epoch\":5,\"stream\":\"events\",\"from\":2,\"through\":5,\"incomplete\":true,\"events\":[{{\"t\":\"text\",\"v\":\"A\",\"seq\":4}},{{\"t\":\"user\",\"id\":2,\"v\":\"again\",\"seq\":5}}]}}", .{});
    defer a.free(page);
    try watch.writeFrame(page, .{ .io = io, .timeout_ms = 2_000 });
    var received: usize = 0;
    const page_deadline = std.Io.Clock.awake.now(io);
    while (page_deadline.untilNow(io, .awake).toMilliseconds() < 2_000 and received < 2) {
        if (try ui.poll(a)) |item| {
            var owned = item;
            defer owned.deinit();
            received += 1;
            if (received == 1) {
                try testing.expectEqualStrings("A", owned.event.text);
                try testing.expectEqual(@as(u64, 4), owned.delivery_sequence);
                try testing.expectEqual(@as(u64, 4), owned.delivery_first_sequence);
                try testing.expect(!owned.history_replay);
            } else {
                try testing.expectEqualStrings("again", owned.event.user_committed.text);
                try testing.expectEqual(@as(u64, 5), owned.delivery_sequence);
                try testing.expectEqual(@as(u64, 5), owned.delivery_first_sequence);
            }
        } else try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(usize, 2), received);
    try testing.expectEqual(@as(u64, 5), client.cursor);
    try testing.expect(std.mem.indexOf(u8, client.pubcfg.notice orelse "", "unavailable") != null);
}
test "coalesced live span is acknowledged as one exact first/last range" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var dir = try unix.Directory.resolveUnder(a, path[0..n], "span", @intCast(std.c.getuid()));
    defer dir.deinit();
    var listener = try unix.Listener.bind(a, &dir, "watch.sock", .{});
    defer listener.deinit();
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.stream = try StreamReceiver.start(a, io, listener.path, client.uid, 5);
    client.stream_expected = true;
    client.need_history = true;
    client.dirty = false;
    var frontend: ?*@import("frontend.zig").Frontend = try @import("frontend.zig").Frontend.start(client);
    defer if (frontend) |live| live.deinit();
    const connection = frontend.?.connection();
    const ui = connection.session_client.?;

    var watch = try listener.accept(.{ .io = io, .timeout_ms = 2_000 });
    defer watch.close();
    const raw_watch = (try watch.readFrame(.{ .io = io, .timeout_ms = 2_000 })).?;
    defer a.free(raw_watch);
    var watch_request = try protocol.parseRequest(a, raw_watch);
    defer watch_request.deinit();
    try testing.expectEqual(protocol.Op.watch, watch_request.op);
    try watch.writeFrame("{\"v\":5,\"id\":1,\"ok\":true,\"epoch\":5,\"through\":0,\"stream\":\"snapshot\",\"snapshot\":{\"background\":{\"active_count\":0},\"epoch\":5,\"attached\":true,\"busy\":true,\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}}", .{ .io = io, .timeout_ms = 2_000 });
    try watch.writeFrame("{\"v\":5,\"id\":1,\"ok\":true,\"epoch\":5,\"stream\":\"baseline\",\"base\":0,\"through\":0,\"entries\":[]}", .{ .io = io, .timeout_ms = 2_000 });
    // Three consecutive raw deltas (positions 4..6) that the display queue
    // coalesces into one payload. Earlier positions were already shortened.
    const page = try std.fmt.allocPrint(a, "{{\"v\":5,\"id\":1,\"ok\":true,\"epoch\":5,\"stream\":\"events\",\"from\":0,\"through\":6,\"incomplete\":true,\"events\":[{{\"t\":\"text\",\"v\":\"a\",\"seq\":4}},{{\"t\":\"text\",\"v\":\"b\",\"seq\":5}},{{\"t\":\"text\",\"v\":\"c\",\"seq\":6}}]}}", .{});
    defer a.free(page);
    try watch.writeFrame(page, .{ .io = io, .timeout_ms = 2_000 });

    // A decoded cursor is not a publication fence: the last item can still be
    // between Client and Communication. Wait on the owned queue under its lock,
    // without consuming the first delta before the complete run is published.
    const communication = frontend.?.communication;
    const merged_deadline = std.Io.Clock.awake.now(io);
    var published = false;
    while (merged_deadline.untilNow(io, .awake).toMilliseconds() < 2_000) {
        communication.ready.drain();
        published = ready: {
            std.debug.assert(std.c.pthread_mutex_lock(&communication.mutex) == .SUCCESS);
            defer std.debug.assert(std.c.pthread_mutex_unlock(&communication.mutex) == .SUCCESS);
            for (communication.displays.items[communication.display_head..]) |display| {
                if (display.value != .event) continue;
                const item = display.value.event;
                if (item.event == .text and item.delivery_epoch == 5 and
                    item.delivery_first_sequence == 4 and item.delivery_sequence == 6 and
                    std.mem.eql(u8, item.event.text, "abc")) break :ready true;
            }
            break :ready false;
        };
        if (published) break;
        const remaining = 2_000 - merged_deadline.untilNow(io, .awake).toMilliseconds();
        if (remaining <= 0) break;
        var wake = [_]std.c.pollfd{.{ .fd = communication.ready.fd, .events = std.c.POLL.IN, .revents = 0 }};
        const result = std.c.poll(&wake, wake.len, @intCast(remaining));
        if (result < 0 and std.c._errno().* != @backingInt(std.c.E.INTR)) return error.PollFailed;
    }
    try testing.expect(published);
    var merged: ?session_client.Item = null;
    const poll_deadline = std.Io.Clock.awake.now(io);
    while (poll_deadline.untilNow(io, .awake).toMilliseconds() < 2_000) {
        if (try ui.poll(a)) |item| {
            merged = item;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    defer if (merged) |*item| item.deinit();
    try testing.expectEqualStrings("abc", merged.?.event.text);
    try testing.expect(std.mem.indexOf(u8, client.pubcfg.notice orelse "", "unavailable") != null);
    try testing.expectEqual(@as(u64, 4), merged.?.delivery_first_sequence);
    try testing.expectEqual(@as(u64, 6), merged.?.delivery_sequence);
    // The whole span is proven, not only position 6; the receiver writes one
    // exact range frame and no intermediate positions stay phantom.
    try ui.acknowledgeRange(5, merged.?.delivery_first_sequence, merged.?.delivery_sequence);
    const span = (try readWatchFrame(&watch, a)).ack;
    try testing.expectEqual(@as(u64, 4), span.first);
    try testing.expectEqual(@as(u64, 6), span.sequence);
    try ackReply(&watch, a, span.id, 5, span.first, span.sequence, 3, true);
    const settled = std.Io.Clock.awake.now(io);
    while (settled.untilNow(io, .awake).toMilliseconds() < 2_000) {
        if (client.stream.?.ackState().pending == 0) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(@as(usize, 0), client.stream.?.ackState().pending);
    try testing.expectEqual(@as(u64, 3), client.stream.?.ackState().confirmed_through);
    var quiet = [_]std.c.pollfd{.{ .fd = watch.fd, .events = std.c.POLL.IN, .revents = 0 }};
    try testing.expectEqual(@as(c_int, 0), std.c.poll(&quiet, 1, 40));
}
test "a v1 worker handshake is refused, while an exact v4 worker is adopted" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var dir = try unix.Directory.resolveUnder(a, path[0..n], "v1peer", @intCast(std.c.getuid()));
    defer dir.deinit();
    var listener = try unix.Listener.bind(a, &dir, "worker.sock", .{});
    defer listener.deinit();
    const id = try ids.generate(io);
    var saw_v4 = std.atomic.Value(bool).init(false);
    var peer = try std.Io.concurrent(io, protocolVersionPeer, .{ a, io, &listener, &saw_v4, id, path[0..n] });
    var peer_pending = true;
    defer if (peer_pending) peer.cancel(io);
    {
        const client = try Client.init(a, io, null, .foreground, path[0..n], path[0..n]);
        defer client.deinit();

        const record: registry.Record = .{
            .id = id,
            .project = path[0..n],
            .endpoint = listener.path,
            .owner = .foreground,
            .owner_instance = "0123456789abcdef",
            .state = "running",
            .pid = @intCast(std.c.getpid()),
            .generation = 1,
        };
        // A v1 envelope for the v4 greeting: explicit, sanitized refusal.
        try testing.expectError(error.ProtocolMismatch, client.attachRecorded(&record, id, false));
        try testing.expect(client.conn == null and client.session == null);
        try testing.expectEqual(@as(u64, 0), client.epoch);
        try testing.expect(client.stream == null);
        try testing.expectEqualStrings(
            "Session worker speaks an incompatible Thin protocol version; restart Thin to start a compatible worker",
            session_client.describe(error.ProtocolMismatch),
        );
        // A v1 worker that simply rejects and closes the v4 frame is the same
        // fail-closed class: no adoption and no automatic restart or kill.
        try testing.expectEqual(AttachStage.outdated, try client.attachEndpoint(&record, id, false));
        try testing.expect(client.conn == null and client.session == null and client.epoch == 0);
        // The compatible path is unchanged: exact v4 greeting, session identity,
        // watch capability and attach epoch are accepted together.
        try testing.expect(try client.attachRecorded(&record, id, false));
        try testing.expect(client.conn != null and client.stream != null);
        try testing.expectEqual(@as(u64, 7), client.epoch);
        try testing.expectEqual(id, client.session.?);
    }
    // The block's deferred client.deinit() joins the subscription before the
    // peer task is awaited, so the fake worker never outlives its sockets.
    peer.await(io);
    peer_pending = false;
    try testing.expect(saw_v4.load(.acquire));
}
test "buffered event readiness and draining never fetch a new socket page" {
    var pair = try pairOf(testing.allocator);
    defer pair.deinit();
    const client = pair.client;
    try testing.expect(!Client.bufferedFn(client));
    {
        var event = try session_client.ownEvent(testing.allocator, 5, .{ .text = "already decoded" });
        errdefer event.deinit();
        try client.pending.append(testing.allocator, event);
    }
    try testing.expect(Client.bufferedFn(client));
    var received = (try Client.pollFn(client, testing.allocator)).?;
    defer received.deinit();
    try testing.expectEqualStrings("already decoded", received.event.text);
    try testing.expect(!Client.bufferedFn(client));
    try expectNoFrame(&pair);
}
test "refused cancel clear refreshes and reports QueueChanged" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // The host kept the barrier (`canceled:false`), so the caller must not see a
    // success; the following real snapshot is what proves the refusal moved the
    // queue revision instead of leaving a stale one behind.
    try pair.reply(1, "\"canceled\":false");
    try pair.reply(2, "\"snapshot\":{}");
    try testing.expectError(error.QueueChanged, Client.cancelClearFn(@ptrCast(client), 5, 9));

    const clear = try readFrameJson(&pair, a);
    defer clear.deinit();
    try testing.expectEqualStrings("cancel_clear", clear.value.object.get("op").?.string);
    try testing.expectEqual(@as(i64, 5), clear.value.object.get("epoch").?.integer);
    try testing.expectEqual(@as(i64, 9), clear.value.object.get("revision").?.integer);

    const refresh = try readFrameJson(&pair, a);
    defer refresh.deinit();
    try testing.expectEqualStrings("snapshot", refresh.value.object.get("op").?.string);
}
test "settings requests route to worker epoch or connect setup project" {
    const a = testing.allocator;
    const ops = [_]protocol.Op{
        .settings,      .model_select,   .effort,
        .cycle_effort,  .login,          .preference,
        .setting,       .decision_model, .image_model,
        .proxy_model,   .proxy_address,  .refresh_models,
        .poll_metadata,
    };

    var worker = try pairOf(a);
    defer worker.deinit();
    for (ops) |op| {
        var req = (try worker.client.trySettingsRequest(op)).?;
        defer req.deinit();
        try std.testing.expectEqual(Request.Target.worker, req.target);
        const bytes = try req.out.finish();
        defer worker.client.a.free(bytes);
        var doc = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer doc.deinit();
        try std.testing.expectEqualStrings(@tagName(op), doc.value.object.get("op").?.string);
        try std.testing.expectEqual(@as(i64, 5), doc.value.object.get("epoch").?.integer);
        try std.testing.expect(doc.value.object.get("project") == null);
    }

    var connect_pair = try connectClientWithControl(a);
    defer connect_pair.deinit();
    for (ops) |op| {
        var req = (try connect_pair.client.trySettingsRequest(op)).?;
        defer req.deinit();
        try std.testing.expectEqual(Request.Target.control, req.target);
        const bytes = try req.out.finish();
        defer connect_pair.client.a.free(bytes);
        var doc = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer doc.deinit();
        try std.testing.expectEqualStrings(@tagName(op), doc.value.object.get("op").?.string);
        try std.testing.expectEqualStrings(connect_pair.client.launcher, doc.value.object.get("project").?.string);
        try std.testing.expect(doc.value.object.get("epoch") == null);
    }
    try std.testing.expect(connect_pair.client.conn == null and connect_pair.client.workers == null);
}
test "connect create uses control and reads the session field" {
    const a = testing.allocator;
    const id = "0123456789abcdef0123456789abcdef";
    var pair = try connectClientWithControl(a);
    defer pair.deinit();
    const client = pair.client;

    // The envelope id is not the session identity: a reply without `session`
    // is rejected before any worker endpoint is dialled.
    try pair.reply(1, "\"endpoint\":\"/nonexistent/thin/worker.sock\"");
    try std.testing.expectError(error.ProtocolError, client.ensureSession());
    const create = try readFrameJson(&pair, a);
    defer create.deinit();
    try std.testing.expectEqualStrings("create", create.value.object.get("op").?.string);
    try std.testing.expectEqualStrings(client.launcher, create.value.object.get("project").?.string);
    try std.testing.expect(client.conn == null and client.session == null);

    // With the session field the request continues to the published endpoint.
    try pair.reply(2, "\"session\":\"" ++ id ++ "\",\"endpoint\":\"/nonexistent/thin/worker.sock\"");
    try std.testing.expectError(error.Transport, client.ensureSession());
    const second = try readFrameJson(&pair, a);
    defer second.deinit();
    try std.testing.expectEqualStrings("create", second.value.object.get("op").?.string);
    try std.testing.expect(client.conn == null and client.session == null);
}
test "connect settings stay on control and readiness comes from the owner" {
    const a = testing.allocator;
    var pair = try connectClientWithControl(a);
    defer pair.deinit();
    const client = pair.client;

    // login and its settings refresh both stay on control: no session is made.
    try pair.reply(1, "\"configured\":1");
    try pair.reply(2, "\"available\":true,\"model\":\"m2\",\"configured\":1");
    try Client.configureFn(@ptrCast(client), "test-key");

    const login = try readFrameJson(&pair, a);
    defer login.deinit();
    try std.testing.expectEqualStrings("login", login.value.object.get("op").?.string);
    try std.testing.expectEqualStrings(client.launcher, login.value.object.get("project").?.string);
    try std.testing.expect(login.value.object.get("epoch") == null);

    const settings = try readFrameJson(&pair, a);
    defer settings.deinit();
    try std.testing.expectEqualStrings("settings", settings.value.object.get("op").?.string);
    try std.testing.expectEqualStrings(client.launcher, settings.value.object.get("project").?.string);
    try std.testing.expect(settings.value.object.get("epoch") == null);

    try std.testing.expect(client.conn == null and client.workers == null);
    // Owner readiness enables the next explicit submit without pre-creating.
    try std.testing.expect(client.state.available);
    // A live control transport makes the launcher serve-able for its first
    // submit, but it is still not attached to any session.
    try std.testing.expect(client.snap.available);
    try std.testing.expect(!client.snap.attached);

    // A later projection without the field is fail-closed even on live control.
    // The failed snapshot refresh before it consumed envelope id 3 without a
    // frame, so this settings request is id 4.
    try pair.reply(4, "\"model\":\"m2\"");
    client.refreshSettings();
    client.rebuild();
    try std.testing.expect(!client.pubcfg.available);
    try std.testing.expect(!client.state.available);
    const refresh = try readFrameJson(&pair, a);
    defer refresh.deinit();
    try std.testing.expectEqualStrings("settings", refresh.value.object.get("op").?.string);

    // Metadata polling also uses the setup route and never creates a session.
    try pair.reply(5, "\"changed\":false");
    try std.testing.expect(!Client.pollModelsFn(@ptrCast(client), true));
    const poll = try readFrameJson(&pair, a);
    defer poll.deinit();
    try std.testing.expectEqualStrings("poll_metadata", poll.value.object.get("op").?.string);
    try std.testing.expectEqualStrings(client.launcher, poll.value.object.get("project").?.string);
    try std.testing.expect(poll.value.object.get("wait").?.bool);
    try std.testing.expect(client.conn == null and client.workers == null);
}
test "worker settings callbacks carry the control epoch" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // model_select, then the settings refresh and the snapshot refresh.
    try pair.reply(1, "\"selected\":true");
    try pair.reply(2, "\"available\":true,\"model\":\"m3\"");
    try pair.reply(3, "\"snapshot\":{}");
    try Client.selectModelFn(@ptrCast(client), "m3");

    const select = try readFrameJson(&pair, a);
    defer select.deinit();
    try std.testing.expectEqualStrings("model_select", select.value.object.get("op").?.string);
    try std.testing.expectEqualStrings("m3", select.value.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 5), select.value.object.get("epoch").?.integer);

    const settings = try readFrameJson(&pair, a);
    defer settings.deinit();
    try std.testing.expectEqualStrings("settings", settings.value.object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 5), settings.value.object.get("epoch").?.integer);
    try std.testing.expect(settings.value.object.get("project") == null);
    try std.testing.expect(client.state.available);
}
test "initial settings keep baseline readiness gated until the reply returns" {
    var pair = try pairOf(testing.allocator);
    defer pair.deinit();
    const client = pair.client;
    client.need_history = true;
    client.initial_settings_loading = true;
    // A progress callback has now consumed the baseline, but the settings
    // reply which owns the control socket is still outstanding.
    client.need_history = false;
    client.rebuild();
    try testing.expect(!client.snap.available);
    client.initial_settings_loading = false;
    client.rebuild();
    try testing.expect(client.snap.available);
}
test "settings configuration revision ignores only root envelope and context" {
    var pair = try pairOf(testing.allocator);
    defer pair.deinit();
    const client = pair.client;
    try adoptTestSettings(client, "{\"id\":1,\"model\":\"m1\",\"effort\":\"high\",\"context\":{\"tokens\":1,\"known\":true,\"limit\":10},\"models\":[{\"name\":\"m1\",\"protocol\":\"chat\",\"context_tokens\":32768}]}");
    try testing.expectEqual(@as(u64, 1), client.configuration_revision);
    try testing.expectEqual(@as(usize, 1), client.pubcfg.models.len);
    try testing.expectEqualStrings("m1", client.pubcfg.models[0].name);
    try adoptTestSettings(client, "{\"models\":[{\"context_tokens\":32768,\"protocol\":\"chat\",\"name\":\"m1\"}],\"context\":{\"limit\":10,\"known\":true,\"tokens\":1},\"effort\":\"high\",\"model\":\"m1\",\"id\":2}");
    try testing.expectEqual(@as(u64, 1), client.configuration_revision);
    try adoptTestSettings(client, "{\"id\":3,\"model\":\"m1\",\"effort\":\"high\",\"context\":{\"tokens\":5,\"known\":false,\"limit\":20},\"models\":[{\"name\":\"m1\",\"protocol\":\"chat\",\"context_tokens\":32768}]}");
    try testing.expectEqual(@as(u64, 1), client.configuration_revision);
    const context = client.pubcfg.doc.?.value.object.get("context").?.object;
    try testing.expectEqual(@as(i64, 5), context.get("tokens").?.integer);
    try testing.expect(!context.get("known").?.bool);
    try testing.expectEqual(@as(i64, 20), context.get("limit").?.integer);
    client.rebuild();

    const changes = [_][]const u8{
        "{\"model\":\"m2\",\"effort\":\"high\",\"models\":[{\"name\":\"m1\",\"protocol\":\"chat\",\"context_tokens\":32768}]}",
        "{\"model\":\"m2\",\"effort\":\"low\",\"models\":[{\"name\":\"m1\",\"protocol\":\"chat\",\"context_tokens\":32768}]}",
        "{\"model\":\"m2\",\"effort\":\"low\",\"settings_notice\":\"a\",\"models\":[{\"name\":\"m1\",\"protocol\":\"chat\",\"context_tokens\":32768}]}",
        "{\"model\":\"m2\",\"effort\":\"low\",\"settings_notice\":\"a\",\"metadata_notice\":\"b\",\"models\":[{\"name\":\"m1\",\"protocol\":\"chat\",\"context_tokens\":32768}]}",
        "{\"model\":\"m2\",\"effort\":\"low\",\"settings_notice\":\"a\",\"metadata_notice\":\"b\",\"limits\":{\"command_timeout_ms\":42},\"models\":[{\"name\":\"m1\",\"protocol\":\"chat\",\"context_tokens\":32768}]}",
        "{\"model\":\"m2\",\"effort\":\"low\",\"settings_notice\":\"a\",\"metadata_notice\":\"b\",\"limits\":{\"command_timeout_ms\":42},\"models\":[{\"name\":\"m3\",\"protocol\":\"chat\",\"context_tokens\":32768}]}",
    };
    for (changes, 0..) |json, i| {
        try adoptTestSettings(client, json);
        try testing.expectEqual(@as(u64, @intCast(i + 2)), client.configuration_revision);
        try adoptTestSettings(client, json);
        try testing.expectEqual(@as(u64, @intCast(i + 2)), client.configuration_revision);
        if (i == 4) try testing.expectEqual(@as(u32, 42), client.pubcfg.limits.command_timeout_ms);
    }
    try testing.expectEqual(@as(usize, 1), client.pubcfg.models.len);
    try testing.expectEqualStrings("m3", client.pubcfg.models[0].name);
}
test "public settings equality respects nested fields arrays and depth bound" {
    const cases = [_][2][]const u8{
        .{ "{\"x\":{\"id\":1}}", "{\"x\":{\"id\":2}}" },
        .{ "{\"x\":{\"context\":1}}", "{\"x\":{\"context\":2}}" },
        .{ "{\"x\":[1,2]}", "{\"x\":[2,1]}" },
        .{ "{\"x\":1}", "{\"x\":1.0}" },
        .{ "{\"initial_context\":1}", "{\"initial_context\":2}" },
    };
    for (cases) |case| {
        var a = try std.json.parseFromSlice(std.json.Value, testing.allocator, case[0], .{});
        defer a.deinit();
        var b = try std.json.parseFromSlice(std.json.Value, testing.allocator, case[1], .{});
        defer b.deinit();
        try testing.expect(!publicSettingsEqual(a.value, b.value, 0));
    }
    var nested: [131]u8 = undefined;
    @memset(nested[0..65], '[');
    nested[65] = '0';
    @memset(nested[66..], ']');
    var deep = try std.json.parseFromSlice(std.json.Value, testing.allocator, &nested, .{});
    defer deep.deinit();
    try testing.expect(!publicSettingsEqual(deep.value, deep.value, 0));
}
test "snapshot and settings project into the UI state without pointers" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    try pair.reply(1, "\"available\":true,\"model\":\"m1\",\"provider\":\"deepseek\",\"effort\":\"high\",\"configured\":1,\"providers\":[{\"name\":\"deepseek\"}]");
    var settings = try client.readResponse(1, quick_timeout_ms);
    try client.adoptSettings(settings.object);
    settings.deinit();
    try std.testing.expectEqualStrings("m1", client.pubcfg.model);
    try std.testing.expectEqual(shared.ReasoningEffort.high, client.pubcfg.effort);
    try std.testing.expectEqual(@as(usize, 1), client.pubcfg.providers.len);
    try std.testing.expectEqual(@as(u8, 1), client.pubcfg.configured);

    try pair.reply(2, "\"snapshot\":{\"background\":{\"active_count\":0},\"session\":\"0123456789abcdef0123456789abcdef\",\"project\":\"/p\",\"owner\":\"foreground\",\"busy\":true,\"phase\":\"calling_model\",\"task\":4,\"task_kind\":\"prompt\",\"epoch\":5,\"attached\":true,\"queue_revision\":9,\"steering\":1,\"follow_up\":0,\"previews\":[{\"id\":5,\"kind\":\"steering\",\"text\":\"next\"}],\"ctx\":{\"tokens\":10,\"limit\":100,\"known\":true},\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}");
    var snapshot = try client.readResponse(2, quick_timeout_ms);
    try client.adoptSnapshot(&snapshot);
    snapshot.deinit();
    client.rebuild();

    const published = Client.snapshotFn(@ptrCast(client));
    try std.testing.expect(published.available);
    try std.testing.expect(published.busy);
    try std.testing.expect(published.attached);
    try std.testing.expectEqual(@as(u64, 5), published.control_epoch);
    try std.testing.expectEqual(@as(u64, 9), published.queue_revision);
    try std.testing.expectEqual(@as(usize, 1), published.previews.len);
    try std.testing.expectEqualStrings("next", published.previews[0].text);

    const state = Client.currentFn(@ptrCast(client));
    try std.testing.expect(state.available);
    try std.testing.expect(state.runtime == null);
    try std.testing.expectEqual(@as(?r.ContextSnapshot, .{ .tokens = 10, .limit = 100, .known = true }), state.initial_context);
    try std.testing.expectEqualStrings("m1", state.model);
    try std.testing.expectEqual(@as(u8, 1), state.configured_providers);
    // The projection copies: mutating the wire bytes later cannot reach the UI.
    try std.testing.expect(state.models.len == 0);
}
test "snapshot attachment and owner queues do not replace display items" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    try client.pushEvent(.{ .string = "{\"t\":\"text\",\"epoch\":5,\"v\":\"queued display\"}" });
    try pair.reply(1, "\"snapshot\":{\"background\":{\"active_count\":0},\"epoch\":5,\"attached\":false,\"pending\":99,\"queue_revision\":9,\"queue_paused\":true,\"steering\":2,\"follow_up\":1,\"newest_id\":17,\"newest_bytes\":24,\"previews\":[{\"id\":17,\"kind\":\"steering\",\"text\":\"next\"},{\"id\":18,\"kind\":\"follow_up\",\"text\":\"later\"}],\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}");
    {
        var response = try client.readResponse(1, quick_timeout_ms);
        defer response.deinit();
        try client.adoptSnapshot(&response);
    }
    client.rebuild();
    const first = Client.snapshotFn(@ptrCast(client));
    // The wire attachment flag cannot override the live connection and epoch.
    try testing.expect(first.attached);
    try testing.expectEqual(@as(u64, 5), first.control_epoch);
    try testing.expectEqual(@as(u64, 9), first.queue_revision);
    try testing.expect(first.queue_paused);
    try testing.expectEqual(@as(usize, 2), first.steering);
    try testing.expectEqual(@as(usize, 1), first.follow_up);
    try testing.expectEqual(@as(?u64, 17), first.newest_id);
    try testing.expectEqual(@as(usize, 24), first.newest_bytes);
    try testing.expectEqual(@as(usize, 2), first.previews.len);
    try testing.expectEqual(@as(u64, 17), first.previews[0].id);
    try testing.expectEqual(session_client.QueueKind.steering, first.previews[0].kind);
    try testing.expectEqualStrings("next", first.previews[0].text);
    try testing.expectEqual(@as(u64, 18), first.previews[1].id);
    try testing.expectEqual(session_client.QueueKind.follow_up, first.previews[1].kind);
    try testing.expectEqualStrings("later", first.previews[1].text);
    try testing.expectEqual(@as(usize, 1), client.pending.items.len);
    try testing.expect(Client.bufferedFn(@ptrCast(client)));

    // The pending permission on the wire is not the owned display queue.
    try pair.reply(2, "\"snapshot\":{\"background\":{\"active_count\":0},\"epoch\":5,\"attached\":true,\"pending\":null,\"queue_revision\":10,\"queue_paused\":false,\"steering\":0,\"follow_up\":1,\"previews\":[{\"id\":18,\"kind\":\"follow_up\",\"text\":\"later\"}],\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}");
    {
        var response = try client.readResponse(2, quick_timeout_ms);
        defer response.deinit();
        try client.adoptSnapshot(&response);
    }
    client.rebuild();
    const second = Client.snapshotFn(@ptrCast(client));
    try testing.expect(second.attached);
    try testing.expectEqual(@as(u64, 10), second.queue_revision);
    try testing.expect(!second.queue_paused);
    try testing.expectEqual(@as(usize, 0), second.steering);
    try testing.expectEqual(@as(usize, 1), second.follow_up);
    try testing.expectEqual(@as(usize, 1), second.previews.len);
    try testing.expectEqual(@as(u64, 18), second.previews[0].id);
    try testing.expectEqual(session_client.QueueKind.follow_up, second.previews[0].kind);
    try testing.expectEqualStrings("later", second.previews[0].text);
    try testing.expectEqual(@as(usize, 1), client.pending.items.len);
    var item = (try Client.pollFn(@ptrCast(client), a)) orelse return error.TestUnexpectedResult;
    defer item.deinit();
    try testing.expectEqual(@as(usize, 0), client.pending.items.len);
    try testing.expectEqual(@as(u64, 5), item.epoch);
    try testing.expectEqualStrings("queued display", item.event.text);

    client.epoch = 0;
    client.rebuild();
    try testing.expect(!Client.snapshotFn(@ptrCast(client)).attached);
    client.epoch = 5;
    client.rebuild();
    try testing.expect(Client.snapshotFn(@ptrCast(client)).attached);
    client.loseView();
    client.epoch = 5;
    client.rebuild();
    try testing.expect(!Client.snapshotFn(@ptrCast(client)).attached);
    try testing.expectEqualStrings("queued display", item.event.text);
}
test "decoded display items outlive their wire documents" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    const wire = try a.dupe(u8,
        \\{"t":"assistant","epoch":5,"disp_trunc":true,"canon_complete":false,"blocks":[{"k":"text","v":"answer"},{"k":"reasoning","v":"because"},{"k":"tool_call","id":"call-1","name":"search","args":"q=1","item":"item-1"},{"k":"tool_result","id":"call-1","v":"done","is_error":true,"canceled":true,"trunc":true}]}
    );
    defer a.free(wire);

    // Both the string and object paths release their decoded document before
    // the queued item is consumed. The object path also releases its JSON doc.
    try client.pushEventMode(.{ .string = wire }, true);
    {
        var doc = try std.json.parseFromSlice(std.json.Value, a, wire, .{ .allocate = .alloc_always });
        defer doc.deinit();
        try client.pushEventMode(doc.value, true);
    }
    @memset(wire, 0);
    try testing.expectEqual(@as(usize, 2), client.pending.items.len);
    var first = (try Client.pollFn(@ptrCast(client), a)) orelse return error.TestUnexpectedResult;
    defer first.deinit();
    var second = (try Client.pollFn(@ptrCast(client), a)) orelse return error.TestUnexpectedResult;
    defer second.deinit();
    try testing.expectEqual(@as(usize, 0), client.pending.items.len);
    client.loseView();
    for ([_]*const session_client.Item{ &first, &second }) |item| {
        try testing.expectEqual(@as(u64, 5), item.epoch);
        try testing.expect(item.display_truncated);
        try testing.expect(!item.canonical_complete);
        const blocks = item.event.assistant_committed;
        try testing.expectEqual(@as(usize, 4), blocks.len);
        try testing.expectEqualStrings("answer", blocks[0].text);
        try testing.expectEqualStrings("because", blocks[1].reasoning);
        try testing.expectEqualStrings("call-1", blocks[2].tool_call.id);
        try testing.expectEqualStrings("search", blocks[2].tool_call.name);
        try testing.expectEqualStrings("q=1", blocks[2].tool_call.arguments);
        try testing.expectEqualStrings("item-1", blocks[2].tool_call.item_id.?);
        try testing.expectEqualStrings("call-1", blocks[3].tool_result.call_id);
        try testing.expectEqualStrings("done", blocks[3].tool_result.text);
        try testing.expect(blocks[3].tool_result.is_error);
        try testing.expect(blocks[3].tool_result.canceled);
        try testing.expect(blocks[3].tool_result.truncated);
    }
}
test "grouped subagent progress updates state without dirtying settings" {
    var pair = try pairOf(testing.allocator);
    defer pair.deinit();
    const client = pair.client;

    try pair.reply(1, "\"available\":true,\"model\":\"m1\",\"provider\":\"deepseek\",\"configured\":1");
    var settings = try client.readResponse(1, quick_timeout_ms);
    try client.adoptSettings(settings.object);
    settings.deinit();

    try pair.reply(2, "\"snapshot\":{\"background\":{\"active_count\":0},\"epoch\":5,\"attached\":true,\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}");
    var baseline = try client.readResponse(2, quick_timeout_ms);
    try client.adoptSnapshot(&baseline);
    baseline.deinit();
    client.dirty = false;

    try pair.reply(3, "\"snapshot\":{\"background\":{\"active_count\":0},\"epoch\":5,\"attached\":true,\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null},\"subagents\":{\"group_id\":1,\"revision\":1,\"total\":2,\"running\":2,\"waiting\":0,\"completed\":0,\"failed\":0,\"canceled\":0,\"paused\":0,\"elapsed_ms\":10,\"latest_id\":1,\"text\":\"working\",\"agents\":[{\"id\":1,\"revision\":1,\"phase\":\"running\",\"elapsed_ms\":10,\"text\":\"working\"},{\"id\":2,\"revision\":1,\"phase\":\"running\",\"elapsed_ms\":10,\"text\":\"working\"}]}}");
    var first = try client.readResponse(3, quick_timeout_ms);
    try client.adoptSnapshot(&first);
    first.deinit();
    client.rebuild();
    try testing.expect(!client.dirty);
    try testing.expect(client.cache.subagents_supported);
    try testing.expect(Client.currentFn(@ptrCast(client)).subagents_supported);
    try testing.expectEqual(@as(u32, 2), client.cache.subagents.running);

    try pair.reply(4, "\"snapshot\":{\"background\":{\"active_count\":0},\"epoch\":5,\"attached\":true,\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null},\"subagents\":{\"group_id\":1,\"revision\":2,\"total\":2,\"running\":1,\"waiting\":0,\"completed\":1,\"failed\":0,\"canceled\":0,\"paused\":0,\"elapsed_ms\":250,\"latest_id\":1,\"text\":\"working\",\"agents\":[{\"id\":1,\"revision\":2,\"phase\":\"completed\",\"elapsed_ms\":250,\"text\":\"working\"},{\"id\":2,\"revision\":1,\"phase\":\"running\",\"elapsed_ms\":250,\"text\":\"working\"}]}}");
    var next = try client.readResponse(4, quick_timeout_ms);
    try client.adoptSnapshot(&next);
    next.deinit();
    client.rebuild();
    const state = Client.currentFn(@ptrCast(client));
    try testing.expect(!client.dirty);
    try testing.expectEqual(@as(u32, 1), client.cache.subagents.completed);
    try testing.expectEqual(@as(u64, 250), client.cache.subagents.elapsed_ms);
    try testing.expect(@import("../core/subagent_status.zig").View.eql(client.cache.subagents, state.subagents));
    try testing.expectEqualStrings("m1", state.model);
}
test "per-agent status rows merge bounded wire pages by id and revision" {
    const a = testing.allocator;
    const Agent = @import("../core/subagent_status.zig").AgentView;
    const rows = try a.alloc(Agent, 513);
    defer a.free(rows);
    for (rows, 0..) |*row, i| {
        row.* = .{ .id = @intCast(i + 1), .revision = 1, .phase = .running, .text_len = 2048 };
        @memset(&row.text_buf, '"');
    }
    var pair = try pairOf(a);
    defer pair.deinit();
    const Helper = struct {
        fn send(client: *Client, all: []const @import("../core/subagent_status.zig").AgentView, group: u64, start: usize) !void {
            const fixture_allocator = testing.allocator;
            const end = @min(start + 64, all.len);
            var out = protocol.Out.init(fixture_allocator);
            defer out.deinit();
            try out.ok(1);
            try protocol.encodeSnapshot(&out, .{
                .session = @splat('a'),
                .project = "/tmp",
                .owner = .daemon,
                .epoch = 5,
                .subagents_supported = true,
                .subagents = .{ .group_id = group, .revision = 1, .total = all.len, .running = all.len, .latest_id = if (all.len == 0) 0 else all.len, .page_offset = start, .page_total = all.len, .agents = all[start..end] },
            });
            const bytes = try out.finish();
            defer fixture_allocator.free(bytes);
            try testing.expect(bytes.len <= protocol.max_response);
            const doc = try std.json.parseFromSlice(std.json.Value, fixture_allocator, bytes, .{});
            var response: Response = .{ .doc = doc, .object = doc.value.object, .a = fixture_allocator };
            defer response.deinit();
            try client.adoptSnapshot(&response);
        }
    };
    var offset: usize = 0;
    while (offset < rows.len) : (offset += 64) try Helper.send(pair.client, rows, 1, offset);
    try testing.expectEqual(rows.len, pair.client.cache.subagents.agents.len);
    for (pair.client.cache.subagents.agents, 0..) |row, i| try testing.expectEqual(@as(u64, @intCast(i + 1)), row.id);
    rows[64].revision = 2;
    rows[64].text_buf[0] = 'x';
    try Helper.send(pair.client, rows, 1, 64);
    try testing.expectEqual(@as(u64, 2), pair.client.cache.subagents.agents[64].revision);
    try testing.expectEqual(@as(u8, '"'), pair.client.cache.subagents.agents[0].text_buf[0]);
    try Helper.send(pair.client, rows, 2, 0);
    try testing.expectEqual(@as(usize, 64), pair.client.cache.subagents.agents.len);
}
test "per-agent status rows reject malformed page bounds" {
    const a = testing.allocator;
    const prefix = "{\"group_id\":1,\"revision\":1,\"total\":1,\"running\":1,\"waiting\":0,\"completed\":0,\"failed\":0,\"canceled\":0,\"paused\":0,\"elapsed_ms\":1,\"latest_id\":1,\"text\":\"\",\"agents\":[{\"id\":1,\"revision\":1,\"phase\":\"running\",\"elapsed_ms\":1,\"text\":\"x\"}]";
    for ([_][]const u8{ ",\"page_offset\":64,\"page_total\":1}", ",\"page_offset\":0,\"page_total\":2}", ",\"page_offset\":0,\"page_total\":\"1\"}" }) |suffix| {
        const bytes = try std.mem.concat(a, u8, &.{ prefix, suffix });
        defer a.free(bytes);
        const doc = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
        defer doc.deinit();
        try testing.expectError(error.ProtocolError, decodeSubagentView(a, doc.value));
    }
}
test "per-agent status rows projection survives cache replacement" {
    var pair = try pairOf(testing.allocator);
    defer pair.deinit();
    const client = pair.client;
    client.dirty = false;
    try pair.reply(1, "\"snapshot\":{\"background\":{\"active_count\":0},\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null},\"subagents\":{\"group_id\":1,\"revision\":1,\"total\":1,\"running\":1,\"waiting\":0,\"completed\":0,\"failed\":0,\"canceled\":0,\"paused\":0,\"elapsed_ms\":1,\"latest_id\":1,\"text\":\"x\",\"agents\":[{\"id\":1,\"revision\":1,\"phase\":\"running\",\"elapsed_ms\":1,\"text\":\"first\"}]}}");
    var first = try client.readResponse(1, quick_timeout_ms);
    try client.adoptSnapshot(&first);
    first.deinit();
    client.rebuild();
    const projection = try client.exportProjection();
    defer projection.deinit();
    try pair.reply(2, "\"snapshot\":{\"background\":{\"active_count\":0},\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null},\"subagents\":{\"group_id\":0,\"revision\":0,\"total\":0,\"running\":0,\"waiting\":0,\"completed\":0,\"failed\":0,\"canceled\":0,\"paused\":0,\"elapsed_ms\":0,\"latest_id\":0,\"text\":\"\",\"agents\":[]}}");
    var second = try client.readResponse(2, quick_timeout_ms);
    try client.adoptSnapshot(&second);
    second.deinit();
    client.rebuild();
    try testing.expect(!client.dirty);
    try testing.expect(client.cache.subagents_supported);
    try testing.expectEqualStrings("first", projection.state.subagents.agents[0].latestText());
    try testing.expectEqualStrings("first", projection.snapshot.subagents.agents[0].latestText());
}
test "per-agent status rows retain published arenas across repeated allocation failures" {
    var pair = try pairOf(testing.allocator);
    defer pair.deinit();
    const client = pair.client;
    const Agent = @import("../core/subagent_status.zig").AgentView;
    const rows = try testing.allocator.alloc(Agent, 64);
    for (rows, 0..) |*row, i| {
        row.* = .{ .id = @intCast(i + 1), .revision = 1, .phase = .running, .text_len = 3 };
        @memcpy(row.text_buf[0..3], "old");
    }
    client.cache.subagents = .{ .group_id = 1, .agents = rows };
    client.rebuild();
    const published_slot = client.arena_index;
    const published_revision = client.publication_revision;
    const inactive = published_slot ^ 1;
    client.arenas[inactive].deinit();
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    client.arenas[inactive] = .init(failing.allocator());
    for (0..3) |_| {
        client.rebuild();
        try testing.expectEqual(published_slot, client.arena_index);
        try testing.expectEqual(published_revision, client.publication_revision);
        try testing.expectEqualStrings("old", client.snap.subagents.agents[0].latestText());
        try testing.expectEqualStrings("old", client.state.subagents.agents[63].latestText());
    }
    client.arenas[inactive].deinit();
    // A large row clone forces a second backing allocation in buildState,
    // after buildSnapshot has already succeeded in the unpublished arena.
    var state_failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2, .resize_fail_index = 0 });
    client.arenas[inactive] = .init(state_failing.allocator());
    client.rebuild();
    try testing.expect(state_failing.has_induced_failure);
    try testing.expectEqual(published_slot, client.arena_index);
    try testing.expectEqualStrings("old", client.snap.subagents.agents[0].latestText());
    try testing.expectEqualStrings("old", client.state.subagents.agents[63].latestText());
    client.arenas[inactive].deinit();
    client.arenas[inactive] = .init(testing.allocator);
    rows[0].text_buf[0] = 'n';
    client.rebuild();
    try testing.expectEqual(inactive, client.arena_index);
    try testing.expectEqualStrings("nld", client.snap.subagents.agents[0].latestText());
    try testing.expectEqualStrings("nld", client.state.subagents.agents[0].latestText());
}
test "memory summary-only snapshot publishes once without settings dirtiness" {
    var pair = try pairOf(testing.allocator);
    defer pair.deinit();
    const client = pair.client;
    const first = "\"snapshot\":{\"background\":{\"active_count\":0},\"memory\":{\"enabled\":true,\"revision\":1,\"active\":null,\"queued_count\":0,\"last_terminal\":{\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":1,\"summary\":\"first\"}}}";
    const second = "\"snapshot\":{\"background\":{\"active_count\":0},\"memory\":{\"enabled\":true,\"revision\":1,\"active\":null,\"queued_count\":0,\"last_terminal\":{\"id\":1,\"result\":\"saved\",\"failure\":null,\"saved_count\":1,\"summary\":\"second\"}}}";
    try pair.reply(1, first);
    var response = try client.readResponse(1, quick_timeout_ms);
    try client.adoptSnapshot(&response);
    response.deinit();
    client.dirty = false;
    try pair.reply(2, second);
    var changed = try client.readResponse(2, quick_timeout_ms);
    try client.adoptSnapshot(&changed);
    changed.deinit();
    try testing.expect(client.dirty);
    try testing.expectEqualStrings("second", client.cache.memory.last_terminal.?.summary.text());
    client.dirty = false;
    try pair.reply(3, second);
    var repeated = try client.readResponse(3, quick_timeout_ms);
    try client.adoptSnapshot(&repeated);
    repeated.deinit();
    try testing.expect(!client.dirty);
}
test "Memory closeout nonzero view survives response and client projection lifetime" {
    const expected: memory_status.View = .{
        .enabled = true,
        .revision = 18446744073709551614,
        .active = .{ .id = 9007199254740993, .phase = .extracting },
        .queued_count = 3,
        .last_terminal = .{ .id = 9007199254740992, .result = .failed, .failure = .storage },
    };
    const next: memory_status.View = .{
        .enabled = true,
        .revision = 7,
        .active = .{ .id = 8, .phase = .saving },
        .queued_count = 1,
        .last_terminal = .{ .id = 6, .result = .saved },
    };
    const exported = blk: {
        var pair = try pairOf(testing.allocator);
        defer pair.deinit();
        const client = pair.client;
        try pair.reply(1, "\"snapshot\":{\"background\":{\"active_count\":0},\"session\":\"0123456789abcdef0123456789abcdef\",\"project\":\"/p\",\"owner\":\"foreground\",\"busy\":false,\"phase\":\"calling_model\",\"task\":0,\"task_kind\":\"prompt\",\"epoch\":5,\"attached\":true,\"queue_revision\":9,\"steering\":2,\"follow_up\":1,\"previews\":[],\"memory\":{\"enabled\":true,\"revision\":18446744073709551614,\"active\":{\"id\":9007199254740993,\"phase\":\"extracting\"},\"queued_count\":3,\"last_terminal\":{\"id\":9007199254740992,\"result\":\"failed\",\"failure\":\"storage\",\"saved_count\":0,\"summary\":\"\"}}}");
        var response = try client.readResponse(1, quick_timeout_ms);
        client.adoptSnapshot(&response) catch |err| {
            response.deinit();
            return err;
        };
        response.deinit();
        client.rebuild();
        const state = Client.currentFn(@ptrCast(client));
        const snapshot = Client.snapshotFn(@ptrCast(client));
        try testing.expect(std.meta.eql(expected, state.memory));
        try testing.expect(std.meta.eql(expected, snapshot.memory));
        try testing.expect(!state.busy and !snapshot.busy);
        try testing.expectEqual(@as(?r.State, .calling_model), snapshot.mode);
        try testing.expectEqual(session_client.TaskKind.prompt, snapshot.task_kind);
        try testing.expectEqual(@as(u64, 5), snapshot.control_epoch);
        try testing.expectEqual(@as(u64, 5), state.control_epoch);
        try testing.expectEqual(@as(u64, 9), snapshot.queue_revision);
        try testing.expectEqual(@as(usize, 2), snapshot.steering);
        try testing.expectEqual(@as(usize, 1), snapshot.follow_up);

        const projection = try client.exportProjection();
        errdefer projection.deinit();
        try testing.expect(std.meta.eql(expected, projection.state.memory));
        try testing.expect(std.meta.eql(expected, projection.snapshot.memory));
        try pair.reply(2, "\"snapshot\":{\"background\":{\"active_count\":0},\"busy\":false,\"phase\":\"calling_model\",\"task_kind\":\"prompt\",\"epoch\":5,\"queue_revision\":9,\"steering\":2,\"follow_up\":1,\"memory\":{\"enabled\":true,\"revision\":7,\"active\":{\"id\":8,\"phase\":\"saving\"},\"queued_count\":1,\"last_terminal\":{\"id\":6,\"result\":\"saved\",\"failure\":null,\"saved_count\":0,\"summary\":\"\"}}}");
        var updated = try client.readResponse(2, quick_timeout_ms);
        client.adoptSnapshot(&updated) catch |err| {
            updated.deinit();
            return err;
        };
        updated.deinit();
        client.rebuild();
        try testing.expect(std.meta.eql(next, Client.currentFn(@ptrCast(client)).memory));
        try testing.expect(std.meta.eql(next, Client.snapshotFn(@ptrCast(client)).memory));
        try testing.expect(std.meta.eql(expected, projection.state.memory));
        try testing.expect(std.meta.eql(expected, projection.snapshot.memory));
        break :blk projection;
    };
    defer exported.deinit();
    try testing.expect(std.meta.eql(expected, exported.state.memory));
    try testing.expect(std.meta.eql(expected, exported.snapshot.memory));
}
test "real host settings reply projects providers flags price states and pending effort" {
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const project_len = try tmp.dir.realPath(io, &path_buffer);
    const project = path_buffer[0..project_len];
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("HOME", project);

    const host_id = try ids.generate(io);
    const session_host = @import("../app/session_host.zig");
    const host = try session_host.SessionHost.init(a, io, &environ, .{ .project = project, .id = host_id, .owner = .daemon });
    defer host.deinit();

    const models = [_]core_config.Model{
        .{ .name = "native/official-model", .context_tokens = 32_000, .output_tokens = 4_000 },
        .{ .name = "native/disabled-model", .context_tokens = 64_000 },
    };
    const official = [_]bool{ true, false };
    const disabled = [_]bool{ false, true };
    const providers = [_]picker_module.Provider{
        .{ .name = "native", .allow_custom = true },
        .{ .name = "family", .allow_custom = true },
    };
    var view = HostSettingsView{
        .prev_fn = host.connection.current_fn,
        .prev_context = host.connection.context,
        .models = &models,
        .official = &official,
        .disabled = &disabled,
        .providers = &providers,
    };
    defer {
        host.connection.current_fn = view.prev_fn;
        host.connection.context = view.prev_context;
    }
    host.connection.current_fn = HostSettingsView.current;
    host.connection.context = &view;

    // The real owner frame, not a hand-written fixture object.
    var request = try protocol.parseRequest(a, "{\"v\":5,\"id\":60,\"op\":\"settings\"}");
    defer request.deinit();
    const frame = try host.dispatch(a, &request, 7, true);
    defer a.free(frame);
    var doc = try std.json.parseFromSlice(std.json.Value, a, frame, .{});
    defer doc.deinit();
    const object = switch (doc.value) {
        .object => |map| map,
        else => return error.ProtocolError,
    };

    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    try client.adoptSettings(object);

    // The owner publishes `providers`, so the picker can match model prefixes.
    try std.testing.expectEqual(@as(usize, 2), client.pubcfg.providers.len);
    try std.testing.expectEqualStrings("native", client.pubcfg.providers[0].name);
    try std.testing.expect(client.pubcfg.providers[0].allow_custom);
    try std.testing.expectEqual(@as(usize, 3), decision_picker.count(client.pubcfg.models, client.pubcfg.providers, ""));
    try std.testing.expectEqual(@as(usize, 1), decision_picker.indexOf(client.pubcfg.models, client.pubcfg.providers, "", "native/official-model"));
    try std.testing.expectEqual(@as(usize, 2), decision_picker.indexOf(client.pubcfg.models, client.pubcfg.providers, "", "native/disabled-model"));

    // Both inline flags are index-aligned with the accepted model rows.
    try std.testing.expectEqual(@as(usize, 2), client.pubcfg.context_official.len);
    try std.testing.expectEqual(@as(usize, 2), client.pubcfg.disabled.len);
    for (client.pubcfg.models, 0..) |model, index| {
        if (std.mem.eql(u8, model.name, "native/official-model")) {
            try std.testing.expect(client.pubcfg.context_official[index] and !client.pubcfg.disabled[index]);
            try std.testing.expectEqual(@as(?u32, 4_000), model.output_tokens);
            try std.testing.expectEqual(core_config.ReasoningSource.metadata, model.output_source);
        } else {
            try std.testing.expect(!client.pubcfg.context_official[index] and client.pubcfg.disabled[index]);
            try std.testing.expectEqual(@as(?u32, null), model.output_tokens);
        }
    }

    // Active price protection is not the configured switch, and the pending
    // default effort keeps the owner's `pending_effort` name.
    try std.testing.expect(client.pubcfg.low_price_active);
    try std.testing.expect(!client.pubcfg.low_price_enabled);
    try std.testing.expectEqual(shared.ReasoningEffort.medium, client.pubcfg.pending_effort.?);

    // rebuild/currentFn really publish every parsed field to the UI state.
    client.rebuild();
    const state = Client.currentFn(@ptrCast(client));
    try std.testing.expectEqual(@as(usize, 2), state.models.len);
    try std.testing.expectEqualStrings("native/disabled-model", state.models[1].name);
    try std.testing.expect(state.model_disabled[1] and !state.model_context_official[1]);
    try std.testing.expectEqual(@as(usize, 2), state.model_providers.len);
    try std.testing.expectEqualStrings("native", state.model_providers[0].name);
    try std.testing.expect(state.low_price_input and !state.low_price_input_enabled);
    try std.testing.expectEqual(shared.ReasoningEffort.medium, state.pending_default_effort.?);

    // The real limits object carries the owner's request/task budgets, so the
    // client keeps them instead of the base defaults the decoder started from.
    const limits_object = switch (object.get("limits") orelse return error.ProtocolError) {
        .object => |map| map,
        else => return error.ProtocolError,
    };
    // A missing field or a wrong type is a protocol failure here, never a
    // silent zero that the real Host settings would otherwise pass.
    const decoded_request_timeout_ms = valueU64(limits_object.get("request_timeout_ms") orelse return error.ProtocolError) orelse return error.ProtocolError;
    const decoded_command_timeout_ms = valueU64(limits_object.get("command_timeout_ms") orelse return error.ProtocolError) orelse return error.ProtocolError;
    try std.testing.expectEqual(@as(u64, client.pubcfg.limits.request_timeout_ms), decoded_request_timeout_ms);
    try std.testing.expectEqual(@as(u64, client.pubcfg.limits.command_timeout_ms), decoded_command_timeout_ms);
    try std.testing.expect(client.pubcfg.limits.request_timeout_ms != 0 and client.pubcfg.limits.command_timeout_ms != 0);
}
test "limits decode the request and task budgets with the strict u32 rule" {
    const base = core_config.Limits{
        .command_timeout_ms = 1_000,
        .request_timeout_ms = 300_000,
    };
    const Decoder = struct {
        fn limits(text: []const u8, start: core_config.Limits) !core_config.Limits {
            var doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
            defer doc.deinit();
            return parseLimits(doc.value, start);
        }
    };

    // Non-default budgets decode next to the limits already handled inline.
    const decoded = try Decoder.limits("{\"request_timeout_ms\":10000,\"command_timeout_ms\":123456}", base);
    try std.testing.expectEqual(@as(u32, 10_000), decoded.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 123_456), decoded.command_timeout_ms);

    // A larger configured pair is decoded exactly, not clamped by the base.
    const raised = try Decoder.limits("{\"request_timeout_ms\":60000,\"command_timeout_ms\":900000}", base);
    try std.testing.expectEqual(@as(u32, 60_000), raised.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 900_000), raised.command_timeout_ms);

    // Unparsable text, null, and a negative number keep the inherited values.
    const junk = try Decoder.limits("{\"request_timeout_ms\":\"abc\",\"command_timeout_ms\":null}", base);
    try std.testing.expectEqual(@as(u32, 300_000), junk.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 1_000), junk.command_timeout_ms);
    const negative = try Decoder.limits("{\"request_timeout_ms\":-1,\"command_timeout_ms\":-1}", base);
    try std.testing.expectEqual(@as(u32, 300_000), negative.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 1_000), negative.command_timeout_ms);

    // A non-object limits value leaves every field at its base value.
    const missing = try Decoder.limits("null", base);
    try std.testing.expectEqual(@as(u32, 300_000), missing.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 1_000), missing.command_timeout_ms);
}
test "lost window resets to an owned history snapshot then resumes deltas" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    try pair.reply(1, "\"reset\":true,\"base\":40,\"next\":40,\"epoch\":5,\"events\":[]");
    client.need_history = false;
    try client.readEvents();
    try std.testing.expect(client.need_history);

    const user = try protocol.encodeEvent(a, .{ .user_committed = .{ .id = 1, .text = "hello" } });
    defer a.free(user);
    const assistant = try protocol.encodeEvent(a, .{ .assistant_committed = &.{.{ .text = "hi" }} });
    defer a.free(assistant);
    const permission = try protocol.encodeEvent(a, .{ .permission = .{ .id = 9, .tool_name = "bash", .description = "run" } });
    defer a.free(permission);
    const history = try std.fmt.allocPrint(a, "\"base\":42,\"epoch\":5,\"entries\":[{s},{s},{s}]", .{ user, assistant, permission });
    defer a.free(history);
    try pair.reply(2, history);
    try client.readHistory();
    try std.testing.expectEqual(@as(u64, 42), client.cursor);
    try std.testing.expectEqual(@as(usize, 3), client.pending.items.len);
    // A snapshot page is local replay metadata: the whole page is marked and
    // only its first item announces the reset.
    try std.testing.expect(client.pending.items[0].history_replay);
    try std.testing.expect(client.pending.items[0].history_reset);
    try std.testing.expect(client.pending.items[1].history_replay and !client.pending.items[1].history_reset);
    try std.testing.expect(client.pending.items[2].history_replay and !client.pending.items[2].history_reset);

    var first = client.pending.orderedRemove(0);
    defer first.deinit();
    try std.testing.expectEqual(@as(u64, 5), first.epoch);
    // Moving the owned item preserves its local history metadata.
    try std.testing.expect(first.history_replay and first.history_reset);
    try std.testing.expectEqualStrings("hello", first.event.user_committed.text);
    var second = client.pending.orderedRemove(0);
    defer second.deinit();
    try std.testing.expectEqualStrings("hi", second.event.assistant_committed[0].text);
    var third = client.pending.orderedRemove(0);
    defer third.deinit();
    try std.testing.expectEqualStrings("run", third.event.permission.description);
    try std.testing.expect(third.event.permission.interrupt == null);

    const delta = try protocol.encodeEvent(a, .{ .text = "more" });
    defer a.free(delta);
    const page = try std.fmt.allocPrint(a, "\"base\":42,\"next\":43,\"epoch\":5,\"events\":[{s}]", .{delta});
    defer a.free(page);
    try pair.reply(3, page);
    try client.readEvents();
    try std.testing.expectEqual(@as(u64, 43), client.cursor);
    try std.testing.expectEqual(@as(usize, 1), client.pending.items.len);
    try std.testing.expectEqualStrings("more", client.pending.items[0].event.text);
    // A live delta is display-only: it must never enter input history.
    try std.testing.expect(!client.pending.items[0].history_replay);
    try std.testing.expect(!client.pending.items[0].history_reset);
}
test "a refetched history page resets its first item and an empty page marks nothing" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // Codec provenance (truncation, incomplete canonical list) travels beside
    // the local history markers instead of replacing them.
    const clipped = try protocol.encodeEventMeta(a, .{ .text = "partial" }, .{ .epoch = 5, .truncated = true, .canonical_complete = false });
    defer a.free(clipped);
    const page = try std.fmt.allocPrint(a, "\"base\":12,\"epoch\":5,\"entries\":[{s}]", .{clipped});
    defer a.free(page);
    try pair.reply(1, page);
    try client.readHistory();
    try std.testing.expectEqual(@as(usize, 1), client.pending.items.len);
    try std.testing.expect(client.pending.items[0].history_replay);
    try std.testing.expect(client.pending.items[0].history_reset);
    try std.testing.expect(client.pending.items[0].display_truncated);
    try std.testing.expect(!client.pending.items[0].canonical_complete);

    // An empty page replaces the queue and fabricates no content event; the UI
    // already resets on the epoch switch, so nothing needs a fake "reset" item.
    try pair.reply(2, "\"base\":13,\"epoch\":5,\"entries\":[]");
    try client.readHistory();
    try std.testing.expectEqual(@as(u64, 13), client.cursor);
    try std.testing.expectEqual(@as(usize, 0), client.pending.items.len);
}
test "a history page that fails mid-decode publishes nothing and stays retryable" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // A known resume point: a broken page must not move it forward.
    client.cursor = 7;
    const user = try protocol.encodeEvent(a, .{ .user_committed = .{ .id = 1, .text = "kept" } });
    defer a.free(user);
    // The valid entry decodes first, then a numeric entry is rejected by
    // `pushEvent`: the earlier decoded item is already sitting in the queue.
    const broken = try std.fmt.allocPrint(a, "\"base\":11,\"epoch\":5,\"entries\":[{s},7]", .{user});
    defer a.free(broken);
    try pair.reply(1, broken);
    try testing.expectError(error.ProtocolError, client.readHistory());
    try std.testing.expectEqual(@as(usize, 0), client.pending.items.len);
    try std.testing.expectEqual(@as(u64, 7), client.cursor);

    // The same page, now whole, replays from scratch and marks its first item.
    const page = try std.fmt.allocPrint(a, "\"base\":11,\"epoch\":5,\"entries\":[{s}]", .{user});
    defer a.free(page);
    try pair.reply(2, page);
    try client.readHistory();
    try std.testing.expectEqual(@as(u64, 11), client.cursor);
    try std.testing.expectEqual(@as(usize, 1), client.pending.items.len);
    try std.testing.expect(client.pending.items[0].history_replay);
    try std.testing.expect(client.pending.items[0].history_reset);
    try std.testing.expectEqualStrings("kept", client.pending.items[0].event.user_committed.text);
}
test "proxy allowlist mutation carries the exact model id and publishes an owned list" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // The mutation frame and the settings refresh the adapter sends right after
    // it are both queued before the call reads them.
    try pair.reply(1, "\"note\":0");
    try pair.reply(2, "\"proxy_configured\":true,\"proxy_models\":[\"opencode-go/deepseek-v3\",\"deepseek/deepseek-chat\"],\"proxy_models_truncated\":false");
    try Client.proxyFn(@ptrCast(client), "opencode-go/deepseek-v3", true);

    var mutation = try readFrameJson(&pair, a);
    defer mutation.deinit();
    const root = mutation.value.object;
    try std.testing.expectEqualStrings("proxy_model", root.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 5), root.get("epoch").?.integer);
    try std.testing.expectEqualStrings("opencode-go/deepseek-v3", root.get("name").?.string);
    try std.testing.expectEqual(true, root.get("enabled").?.bool);

    var refresh = try readFrameJson(&pair, a);
    defer refresh.deinit();
    try std.testing.expectEqualStrings("settings", refresh.value.object.get("op").?.string);

    // The published projection owns exact copies of the bounded name list.
    try std.testing.expect(client.state.proxy_configured);
    try std.testing.expectEqual(@as(usize, 2), client.state.proxy_models.len);
    try std.testing.expectEqualStrings("opencode-go/deepseek-v3", client.state.proxy_models[0]);
    try std.testing.expectEqualStrings("deepseek/deepseek-chat", client.state.proxy_models[1]);
}
test "proxy mutations refuse unusable names before any wire traffic" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    try std.testing.expectError(error.InvalidInput, Client.proxyFn(@ptrCast(client), "", true));
    const too_long = try a.alloc(u8, protocol.max_name + 1);
    defer a.free(too_long);
    @memset(too_long, 'm');
    try std.testing.expectError(error.InvalidInput, Client.proxyFn(@ptrCast(client), too_long, true));
    try expectNoFrame(&pair);

    // Disabling an entry is still a real mutation with the same exact name.
    try pair.reply(1, "\"note\":0");
    try pair.reply(2, "\"proxy_configured\":false,\"proxy_models\":[]");
    try Client.proxyFn(@ptrCast(client), "opencode-go/deepseek-v3", false);
    var mutation = try readFrameJson(&pair, a);
    defer mutation.deinit();
    try std.testing.expectEqual(false, mutation.value.object.get("enabled").?.bool);
    try std.testing.expectEqualStrings("opencode-go/deepseek-v3", mutation.value.object.get("name").?.string);
    var refresh = try readFrameJson(&pair, a);
    defer refresh.deinit();
    try std.testing.expect(client.state.proxy_models.len == 0);
    try std.testing.expect(!client.state.proxy_configured);
}
test "proxy endpoint request carries the exact value and publishes an owned IPv6 pair" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    try pair.reply(1, "\"note\":0");
    try pair.reply(2, "\"proxy_configured\":true,\"proxy_address\":\"2001:db8::1\",\"proxy_port\":8080,\"proxy_models\":[\"p/m\"]");
    try Client.proxyAddressFn(@ptrCast(client), "[2001:db8::1]:8080");

    var mutation = try readFrameJson(&pair, a);
    defer mutation.deinit();
    const root = mutation.value.object;
    try std.testing.expectEqualStrings("proxy_address", root.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 5), root.get("epoch").?.integer);
    try std.testing.expectEqualStrings("[2001:db8::1]:8080", root.get("value").?.string);
    try std.testing.expect(root.get("project") == null);

    var refresh = try readFrameJson(&pair, a);
    defer refresh.deinit();
    try std.testing.expectEqualStrings("settings", refresh.value.object.get("op").?.string);

    try std.testing.expectEqualStrings("2001:db8::1", client.state.proxy_address.?);
    try std.testing.expectEqual(@as(u16, 8080), client.state.proxy_port);
    // The published address is an arena-owned copy, not a window into the doc.
    try std.testing.expect(client.state.proxy_address.?.ptr != client.pubcfg.proxy_address.?.ptr);
    try std.testing.expectEqual(@as(usize, 1), client.state.proxy_models.len);

    // An empty value is a real clear request, not an omitted field.
    try pair.reply(3, "\"note\":0");
    try pair.reply(4, "\"proxy_configured\":false,\"proxy_address\":null,\"proxy_port\":0,\"proxy_models\":[]");
    try Client.proxyAddressFn(@ptrCast(client), "");
    var clear = try readFrameJson(&pair, a);
    defer clear.deinit();
    try std.testing.expectEqualStrings("", clear.value.object.get("value").?.string);
    var cleared = try readFrameJson(&pair, a);
    defer cleared.deinit();
    try std.testing.expect(client.state.proxy_address == null);
    try std.testing.expectEqual(@as(u16, 0), client.state.proxy_port);
}
test "proxy endpoint rejects unusable input before any wire traffic" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    for ([_][]const u8{
        "host",
        "2001:db8::1",
        "host:0",
        "host:70000",
        "[2001:db8::1]",
        "user@host:8080",
        "http://host:8080",
        "host:8080/path",
        "bad host:8080",
    }) |value| {
        try std.testing.expectError(error.InvalidInput, Client.proxyAddressFn(@ptrCast(client), value));
    }
    const too_long = try a.alloc(u8, core_config.max_proxy_endpoint_bytes + 1);
    defer a.free(too_long);
    @memset(too_long, 'a');
    try std.testing.expectError(error.InvalidInput, Client.proxyAddressFn(@ptrCast(client), too_long));
    try expectNoFrame(&pair);
}
test "settings keep legacy proxy snapshots readable and never invent endpoints" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // An older owner omits both new fields entirely: configured + allowlist stay
    // readable, the endpoint stays absent and the list is not cleared.
    try pair.reply(1, "\"proxy_configured\":true,\"proxy_models\":[\"opencode-go/deepseek-v3\"]");
    client.refreshSettings();
    client.rebuild();
    try std.testing.expect(client.state.proxy_configured);
    try std.testing.expectEqual(@as(usize, 1), client.state.proxy_models.len);
    try std.testing.expect(client.state.proxy_address == null);
    try std.testing.expectEqual(@as(u16, 0), client.state.proxy_port);

    // A configured snapshot with a malformed pair is dropped as an endpoint but
    // still keeps the allowlist.
    try pair.reply(2, "\"proxy_configured\":true,\"proxy_address\":\"bad host\",\"proxy_port\":8080,\"proxy_models\":[\"opencode-go/deepseek-v3\"]");
    client.refreshSettings();
    client.rebuild();
    try std.testing.expect(client.state.proxy_address == null);
    try std.testing.expectEqual(@as(usize, 1), client.state.proxy_models.len);

    // A configured=false snapshot carrying a host is not trusted either.
    try pair.reply(3, "\"proxy_configured\":false,\"proxy_address\":\"10.0.0.9\",\"proxy_port\":3128,\"proxy_models\":[]");
    client.refreshSettings();
    client.rebuild();
    try std.testing.expect(client.state.proxy_address == null);
    try std.testing.expectEqual(@as(u16, 0), client.state.proxy_port);

    // A complete IPv4 pair is adopted exactly.
    try pair.reply(4, "\"proxy_configured\":true,\"proxy_address\":\"10.0.0.9\",\"proxy_port\":3128,\"proxy_models\":[]");
    client.refreshSettings();
    client.rebuild();
    try std.testing.expectEqualStrings("10.0.0.9", client.state.proxy_address.?);
    try std.testing.expectEqual(@as(u16, 3128), client.state.proxy_port);
}
test "stale control epoch pages are dropped instead of rendered" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    const delta = try protocol.encodeEvent(a, .{ .text = "old controller" });
    defer a.free(delta);
    const page = try std.fmt.allocPrint(a, "\"base\":1,\"next\":2,\"epoch\":99,\"events\":[{s}]", .{delta});
    defer a.free(page);
    try pair.reply(1, page);
    try client.readEvents();
    // Nothing from a replaced console is rendered and the cursor does not move;
    // control revocation itself comes from the owner snapshot, not a delta page.
    try std.testing.expectEqual(@as(usize, 0), client.pending.items.len);
    try std.testing.expectEqual(@as(u64, 0), client.cursor);
    try std.testing.expectEqual(@as(u64, 5), client.epoch);

    // Same rule when the codec reports the foreign epoch on the event itself.
    try pair.reply(2, "\"base\":1,\"next\":2,\"epoch\":5,\"events\":[]");
    try client.readEvents();
    try std.testing.expectEqual(@as(u64, 0), client.pending.items.len);
}
test "request builder owns implicit root and fails locally before socket writes" {
    const Helper = struct {
        fn build(a: std.mem.Allocator, client: *Client) !void {
            const saved = client.a;
            client.a = a;
            defer client.a = saved;
            var request_ = try client.request(.submit);
            defer request_.deinit();
            try request_.put("epoch", @as(u64, 5));
            try request_.put("req", @as(u64, 99));
            try request_.put("kind", "prompt");
            try request_.put("text", "complete 中文 input");
            const bytes = try request_.out.finish();
            defer a.free(bytes);
            var parsed = try protocol.parseRequest(a, bytes);
            defer parsed.deinit();
            try testing.expectEqual(protocol.Op.submit, parsed.op);
            try testing.expectEqual(request_.id, parsed.id);
            try testing.expectEqual(@as(u64, 99), try parsed.u64Field("req"));
            try testing.expectEqualStrings("complete 中文 input", try parsed.stringField("text", null));
        }
    };
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    try testing.checkAllAllocationFailures(a, Helper.build, .{pair.client});
    // Building, including every failed allocation, must not transmit a prefix.
    try testing.expect((try pair.server.readStep()) == .pending);
    try testing.expectEqual(@as(usize, 0), pair.server.header_read);
    try testing.expect(pair.client.conn != null);
    try testing.expectEqual(@as(u64, 5), pair.client.epoch);
}
test "approve and withdraw carry their own payload ids" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    var approve = try client.request(.approve);
    defer approve.deinit();
    try approve.put("epoch", client.epoch);
    try approve.put("permission_id", @as(u64, 77));
    try approve.put("allow", true);
    const approve_bytes = try approve.out.finish();
    defer a.free(approve_bytes);
    var approve_doc = try std.json.parseFromSlice(std.json.Value, a, approve_bytes, .{});
    defer approve_doc.deinit();
    try std.testing.expectEqualStrings("approve", approve_doc.value.object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 77), approve_doc.value.object.get("permission_id").?.integer);
    try std.testing.expect(approve_doc.value.object.get("id").?.integer != 77);
    try std.testing.expectEqual(@as(i64, protocol.version), approve_doc.value.object.get("v").?.integer);

    var withdraw = try client.request(.withdraw);
    defer withdraw.deinit();
    try withdraw.put("epoch", client.epoch);
    try withdraw.put("queue_id", @as(u64, 12));
    const withdraw_bytes = try withdraw.out.finish();
    defer a.free(withdraw_bytes);
    var withdraw_doc = try std.json.parseFromSlice(std.json.Value, a, withdraw_bytes, .{});
    defer withdraw_doc.deinit();
    try std.testing.expectEqual(@as(i64, 12), withdraw_doc.value.object.get("queue_id").?.integer);
    try std.testing.expectEqual(@as(i64, protocol.version), withdraw_doc.value.object.get("v").?.integer);

    // A reply carrying its own text still round-trips through withdraw.
    try pair.reply(3, "\"text\":\"queued text\"");
    var resp = try client.readResponse(3, quick_timeout_ms);
    defer resp.deinit();
    try std.testing.expectEqualStrings("queued text", resp.text("text").?);
}
test "version and id are checked before ok/err, then the view is dropped" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;

    // A typed wire error is attributable, so the view survives it.
    try pair.replyError(1, "stale_control");
    try std.testing.expectError(error.StaleControl, client.readResponse(1, quick_timeout_ms));
    try std.testing.expect(client.conn != null);
    try pair.replyError(2, "busy");
    try std.testing.expectError(error.Busy, client.readResponse(2, quick_timeout_ms));
    try std.testing.expect(client.conn != null);

    // A wrong id cannot be attributed to this request, so `ok` is irrelevant:
    // the frame is rejected as protocol error and the view is dropped.
    const wait = unix.Wait{ .io = std.testing.io, .timeout_ms = 5_000 };
    try pair.server.writeFrame("{\"v\":5,\"id\":9,\"ok\":false,\"err\":\"busy\"}", wait);
    try std.testing.expectError(error.ProtocolError, client.readResponse(2, quick_timeout_ms));
    try std.testing.expect(client.conn == null);
    try std.testing.expectEqual(@as(u64, 0), client.epoch);
}
test "wrong protocol version is a protocol error even with ok true" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    const wait = unix.Wait{ .io = std.testing.io, .timeout_ms = 5_000 };
    try pair.server.writeFrame("{\"v\":9,\"id\":1,\"ok\":true}", wait);
    try std.testing.expectError(error.ProtocolError, client.readResponse(1, quick_timeout_ms));
    try std.testing.expect(client.conn == null);
}
test "mutating ops send a real frame and adopt the accepted reply" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    const wait = unix.Wait{ .io = std.testing.io, .timeout_ms = 5_000 };

    // The sequential envelope id is allocated first; the receipt nonce is a
    // separate cryptographically random value, so only one id is consumed.
    const submit_id = client.next_req + 1;
    try pair.reply(submit_id, "\"accepted\":true,\"duplicate\":false,\"task\":11");
    try Client.submitFn(@ptrCast(client), client.epoch, .prompt, "hello");
    const frame = (try pair.server.readFrame(wait)) orelse return error.Transport;
    defer a.free(frame);
    var parsed = try protocol.parseRequest(a, frame);
    defer parsed.deinit();
    try std.testing.expectEqual(submit_id, parsed.id);
    const receipt_nonce = try parsed.u64Field("req");
    try std.testing.expect(receipt_nonce != 0);
    var doc = try std.json.parseFromSlice(std.json.Value, a, frame, .{});
    defer doc.deinit();
    const object = doc.value.object;
    try std.testing.expectEqual(@as(i64, protocol.version), object.get("v").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(submit_id)), object.get("id").?.integer);
    try std.testing.expectEqualStrings("submit", object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 5), object.get("epoch").?.integer);
    try std.testing.expectEqualStrings("prompt", object.get("kind").?.string);
    try std.testing.expectEqualStrings("hello", object.get("text").?.string);
    // Accepted: the receipt is confirmed, the task is mirrored and the owner
    // echo of this prompt is suppressed exactly once.
    try std.testing.expect(client.receipt == null);
    try std.testing.expect(client.cache.busy);
    try std.testing.expect(client.suppress != null);

    const cancel_id = client.next_req + 1;
    try pair.reply(cancel_id, "\"canceled\":true");
    try Client.cancelFn(@ptrCast(client), client.epoch);
    const cancel_frame = (try pair.server.readFrame(wait)) orelse return error.Transport;
    defer a.free(cancel_frame);
    var cancel_doc = try std.json.parseFromSlice(std.json.Value, a, cancel_frame, .{});
    defer cancel_doc.deinit();
    try std.testing.expectEqual(@as(i64, protocol.version), cancel_doc.value.object.get("v").?.integer);
    try std.testing.expectEqualStrings("cancel", cancel_doc.value.object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 5), cancel_doc.value.object.get("epoch").?.integer);
}
test "submit receipts are random non-zero and bound to one unconfirmed session" {
    const a = testing.allocator;
    const session_a: ids.Id = "0123456789abcdef0123456789abcdef".*;
    const session_b: ids.Id = "fedcba9876543210fedcba9876543210".*;

    var first_pair = try pairOf(a);
    defer first_pair.deinit();
    const first_client = first_pair.client;
    first_client.session = session_a;

    // A fresh logical submission takes the normal submit route and gets a
    // random non-zero receipt.
    const first_id = first_client.next_req + 1;
    try first_pair.replyError(first_id, "busy");
    try std.testing.expectError(error.Busy, Client.submitFn(@ptrCast(first_client), first_client.epoch, .prompt, "hello"));
    const first = try readSubmitFrame(&first_pair, a);
    try std.testing.expectEqual(first_id, first.id);
    try std.testing.expect(first.req != 0);
    try std.testing.expect(first_client.receipt != null and first_client.receipt.?.req == first.req);

    // An explicit retry of the same session/kind/digest first asks the owner
    // about the old nonce. A rejected receipt lets the explicit action mint a
    // new nonce; it does not blindly reuse the old submit.
    try first_pair.reply(first_client.next_req + 1, "\"snapshot\":{},\"receipt_known\":true,\"receipt_accepted\":false");
    try first_pair.reply(first_client.next_req + 2, "\"accepted\":true,\"duplicate\":false,\"task\":12");
    try Client.submitFn(@ptrCast(first_client), first_client.epoch, .prompt, "hello");
    const query_frame = (try first_pair.server.readFrame(.{ .io = std.testing.io, .timeout_ms = 5_000 })) orelse return error.Transport;
    defer a.free(query_frame);
    var query = try protocol.parseRequest(a, query_frame);
    defer query.deinit();
    try std.testing.expectEqual(protocol.Op.snapshot, query.op);
    try std.testing.expectEqual(first.req, try query.u64Field("receipt"));
    const retried = try readSubmitFrame(&first_pair, a);
    try std.testing.expect(first_client.poll_error != null and first_client.poll_error.? == error.ProtocolError);
    try std.testing.expect(retried.req != 0 and retried.req != first.req);
    try std.testing.expect(first_client.receipt == null);

    // A different digest is a new logical submission and mints a new nonce
    // without querying the abandoned pending receipt.
    const changed_id = first_client.next_req + 1;
    try first_pair.replyError(changed_id, "busy");
    try std.testing.expectError(error.Busy, Client.submitFn(@ptrCast(first_client), first_client.epoch, .prompt, "hello again"));
    const changed = try readSubmitFrame(&first_pair, a);
    try std.testing.expect(changed.req != 0 and changed.req != first.req);
    try std.testing.expectEqual(session_a, first_client.receipt.?.session.?);

    // The same kind and digest in another session is not the same submission;
    // the old pending receipt is dropped, never replayed.
    first_client.session = session_b;
    const other_session_id = first_client.next_req + 1;
    try first_pair.replyError(other_session_id, "busy");
    try std.testing.expectError(error.Busy, Client.submitFn(@ptrCast(first_client), first_client.epoch, .prompt, "hello again"));
    const other_session = try readSubmitFrame(&first_pair, a);
    try std.testing.expect(other_session.req != 0 and other_session.req != changed.req);
    try std.testing.expectEqual(session_b, first_client.receipt.?.session.?);

    // A different frontend has its own envelope sequence and must not reuse the
    // receipt of another frontend for the same prompt.
    var second_pair = try pairOf(a);
    defer second_pair.deinit();
    const second_client = second_pair.client;
    second_client.session = session_a;
    const second_id = second_client.next_req + 1;
    try second_pair.replyError(second_id, "busy");
    try std.testing.expectError(error.Busy, Client.submitFn(@ptrCast(second_client), second_client.epoch, .prompt, "hello again"));
    const second = try readSubmitFrame(&second_pair, a);
    try std.testing.expectEqual(second_id, second.id);
    try std.testing.expect(second.req != 0 and second.req != changed.req);
    try std.testing.expectEqual(session_a, second_client.receipt.?.session.?);
}
test "receipt snapshot error preserves accepted receipt and recovers cache" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;

    try pair.reply(1, "\"snapshot\":{\"background\":{\"active_count\":0},\"busy\":false,\"task\":7,\"epoch\":5,\"attached\":true,\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}");
    client.refreshSnapshot();
    const initial_frame = try readFrameJson(&pair, a);
    defer initial_frame.deinit();
    const old_cache = client.cache;

    try pair.replyError(2, "busy");
    try testing.expectError(error.Busy, Client.submitFn(@ptrCast(client), client.epoch, .prompt, "hello"));
    const submit = try readSubmitFrame(&pair, a);
    try testing.expect(submit.req != 0);

    try pair.reply(3, "\"snapshot\":{\"busy\":true,\"task\":999,\"memory\":null},\"receipt_known\":true,\"receipt_accepted\":true,\"receipt_task\":42");
    try Client.submitFn(@ptrCast(client), client.epoch, .prompt, "hello");
    const query = try readFrameJson(&pair, a);
    defer query.deinit();
    try testing.expectEqualStrings("snapshot", query.value.object.get("op").?.string);
    try testing.expectEqual(submit.req, valueU64(query.value.object.get("receipt").?).?);
    try expectNoFrame(&pair);
    try testing.expect(client.receipt == null);
    try testing.expect(client.suppress != null);
    try testing.expect(client.poll_error != null and client.poll_error.? == error.ProtocolError);
    // Confirmation intentionally updates task/busy; the invalid projection
    // must not publish any of its other data.
    var confirmed = old_cache;
    confirmed.busy = true;
    confirmed.task = 42;
    confirmed.kind = .prompt;
    try testing.expect(std.meta.eql(confirmed, client.cache));

    try pair.reply(4, "\"snapshot\":{\"background\":{\"active_count\":0},\"busy\":false,\"task\":55,\"epoch\":5,\"attached\":true,\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}");
    client.refreshSnapshot();
    const refresh = try readFrameJson(&pair, a);
    defer refresh.deinit();
    try testing.expectEqualStrings("snapshot", refresh.value.object.get("op").?.string);
    try testing.expectEqual(@as(u64, 55), client.cache.task);
    try testing.expect(!client.cache.busy);
}
test "accepted pending receipt is confirmed by query instead of resubmitted" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;
    client.receipt = .{ .req = 424242, .kind = .prompt, .digest = submissionDigest(.prompt, "hello"), .session = session_id };

    try pair.reply(1, "\"snapshot\":{},\"receipt_known\":true,\"receipt_accepted\":true,\"receipt_task\":42");
    try Client.submitFn(@ptrCast(client), client.epoch, .prompt, "hello");

    const query = try readFrameJson(&pair, a);
    defer query.deinit();
    try std.testing.expectEqualStrings("snapshot", query.value.object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 424242), query.value.object.get("receipt").?.integer);
    // No submit follows: the original task is confirmed exactly once.
    try expectNoFrame(&pair);
    try std.testing.expect(client.receipt == null);
    try std.testing.expectEqual(@as(u64, 42), client.cache.task);
    try std.testing.expect(client.suppress != null);
}
test "unknown or evicted pending receipt refuses to resubmit" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;
    client.receipt = .{ .req = 777777, .kind = .prompt, .digest = submissionDigest(.prompt, "hello"), .session = session_id };

    try pair.reply(1, "\"snapshot\":{},\"receipt_known\":false");
    try std.testing.expectError(error.Unavailable, Client.submitFn(@ptrCast(client), client.epoch, .prompt, "hello"));
    const query = try readFrameJson(&pair, a);
    defer query.deinit();
    try std.testing.expectEqualStrings("snapshot", query.value.object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 777777), query.value.object.get("receipt").?.integer);
    try expectNoFrame(&pair);
    try std.testing.expect(client.receipt != null and client.receipt.?.req == 777777);
    try std.testing.expect(client.poll_error != null and client.poll_error.? == error.ProtocolError);
    try std.testing.expect(std.mem.indexOf(u8, client.pubcfg.notice orelse "", "not resubmitted") != null);

    // A failed query is equally uncertain: keep the pending receipt.
    try pair.replyError(2, "busy");
    try std.testing.expectError(error.Unavailable, Client.submitFn(@ptrCast(client), client.epoch, .prompt, "hello"));
    const failed = try readFrameJson(&pair, a);
    defer failed.deinit();
    try std.testing.expectEqualStrings("snapshot", failed.value.object.get("op").?.string);
    try expectNoFrame(&pair);
    try std.testing.expect(client.receipt != null);
}
test "lost view cannot create a new session to resend a pending receipt" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var pair = try connectClientWithControl(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;
    client.epoch = 5;
    client.receipt = .{ .req = 888888, .kind = .prompt, .digest = submissionDigest(.prompt, "hello"), .session = session_id };

    try std.testing.expectError(error.Unavailable, Client.submitFn(@ptrCast(client), client.epoch, .prompt, "hello"));
    // No create and no query: attaching the original session is required first.
    try expectNoFrame(&pair);
    try std.testing.expect(client.conn == null and client.session != null);
    try std.testing.expect(client.receipt != null and client.receipt.?.req == 888888);
    try std.testing.expect(std.mem.indexOf(u8, client.pubcfg.notice orelse "", "Attach the original session") != null);
}
test "codec flags merge conservatively and a wire epoch is verified" {
    const a = testing.allocator;
    const body = [_]u8{'a'};
    const blocks = [_]p.Block{.{ .text = &body }};
    var item = try session_client.ownEvent(a, 4, .{ .assistant_committed = &blocks });
    defer item.deinit();
    try std.testing.expect(item.canonical_complete);
    try std.testing.expect(!item.display_truncated);

    const doc = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    var decoded: protocol.DecodedEvent = .{
        .epoch = 0,
        .event = .{ .text = "" },
        .display_truncated = true,
        .canonical_complete = false,
        .doc = doc,
    };
    defer decoded.deinit();
    mergeFlags(&item, &decoded);
    // A block list cut by the codec's 256-block bound is never a final answer.
    try std.testing.expect(!item.canonical_complete);
    try std.testing.expect(item.display_truncated);
    // No wire claim keeps this view's epoch; a foreign epoch drops the event.
    try std.testing.expectEqual(@as(?u64, 4), itemEpoch(4, &decoded));
    decoded.epoch = 9;
    try std.testing.expectEqual(@as(?u64, null), itemEpoch(4, &decoded));
    decoded.epoch = 4;
    try std.testing.expectEqual(@as(?u64, 4), itemEpoch(4, &decoded));
}
test "wire error codes keep the classification describe already knows" {
    try std.testing.expectEqual(error.StaleControl, wireError(.stale_control));
    try std.testing.expectEqual(error.Busy, wireError(.busy));
    try std.testing.expectEqual(error.QueueFull, wireError(.queue_full));
    try std.testing.expectEqual(error.QueueEmpty, wireError(.queue_empty));
    try std.testing.expectEqual(error.PermissionExpired, wireError(.permission_expired));
    try std.testing.expectEqual(error.SessionNotFound, wireError(.not_found));
    try std.testing.expectEqual(error.InputTooLarge, wireError(.input_too_large));
    try std.testing.expectEqual(error.ProtocolError, wireError(.bad_request));
    try std.testing.expect(std.mem.find(u8, session_client.describe(error.StaleControl), "takeover") != null);
}
test "refresh wire codes survive a real failing frame without collapsing" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    const wait = unix.Wait{ .io = std.testing.io, .timeout_ms = 5_000 };

    const cases = [_]struct { code: protocol.ErrorCode, expected: anyerror }{
        .{ .code = .no_official_provider, .expected = error.NoOfficialProvider },
        .{ .code = .metadata_refresh_busy, .expected = error.MetadataRefreshBusy },
    };
    for (cases, 1..) |case, id| {
        var out = protocol.Out.init(a);
        defer out.deinit();
        try out.fail(id, case.code);
        const bytes = try out.finish();
        defer a.free(bytes);
        try pair.server.writeFrame(bytes, wait);

        // Full path: strict frame parse -> codeFromName -> wireError.
        try std.testing.expectError(case.expected, client.readResponse(id, quick_timeout_ms));
        try std.testing.expect(case.expected != error.Transport);
        try std.testing.expect(case.expected != error.RemoteFailure);
        try std.testing.expectEqual(case.expected, wireError(protocol.codeFromName(case.code.name())));
    }

    // An unknown name still degrades to the generic remote failure only.
    try std.testing.expectEqual(error.RemoteFailure, wireError(protocol.codeFromName("not_a_wire_code")));
}
test "cycle effort preserves closed capability errors through RPC" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    const cases = [_]struct { expected: anyerror, name: []const u8 }{
        .{ .expected = error.ThinkingCapabilitiesLoading, .name = "thinking_capabilities_loading" },
        .{ .expected = error.ThinkingCapabilitiesUnknown, .name = "thinking_capabilities_unknown" },
    };
    for (cases) |case| {
        const code = protocol.errorCode(case.expected);
        try testing.expectEqualStrings(case.name, code.name());
        try testing.expectEqual(code, protocol.codeFromName(case.name));
        try testing.expectEqual(case.expected, wireError(protocol.codeFromName(code.name())));
        try pair.replyError(pair.nextId(), code.name());
        try testing.expectError(case.expected, Client.cycleEffortFn(@ptrCast(pair.client)));
        const request = try readFrameJson(&pair, a);
        defer request.deinit();
        try testing.expectEqualStrings("cycle_effort", request.value.object.get("op").?.string);
        try testing.expectEqual(@as(i64, 5), request.value.object.get("epoch").?.integer);
    }
    try testing.expectEqual(protocol.ErrorCode.internal, protocol.codeFromName("not_a_wire_code"));
    try testing.expectEqual(error.RemoteFailure, wireError(protocol.codeFromName("not_a_wire_code")));
    try testing.expectEqual(protocol.ErrorCode.internal, protocol.errorCode(error.Unexpected));
}
test "deep valid frames use dynamic validation and malformed grammar is rejected" {
    const a = testing.allocator;
    const json = @import("../app/json_bound.zig");
    try json.validate(a, "{\"v\":1,\"id\":1,\"ok\":true}");
    try json.validate(a, "{\"a\":\"}}}}[[[[\"}");
    var deep: [167]u8 = undefined;
    @memcpy(deep[0..5], "{\"a\":");
    @memset(deep[5..85], '[');
    deep[85] = '0';
    @memset(deep[86..166], ']');
    deep[166] = '}';
    var parsed = try parseObject(a, &deep);
    defer parsed.deinit();
    try std.testing.expectError(error.ProtocolError, parseObject(a, deep[5..85]));
    try std.testing.expectError(error.ProtocolError, parseObject(a, "not json"));
    try std.testing.expectError(error.ProtocolError, parseObject(a, "[1,2,3]"));
}
test "effort levels and configured masks decode from either shape" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[\"off\",\"low\",\"high\"]", .{});
    defer parsed.deinit();
    const set = parseEfforts(parsed.value);
    try std.testing.expect(set.contains(.low));
    try std.testing.expect(set.contains(.high));
    try std.testing.expect(!set.contains(.max));
    try std.testing.expectEqual(@as(u8, 0xff), parseConfigured(.{ .bool = true }));
    try std.testing.expectEqual(@as(u8, 0), parseConfigured(.{ .integer = 0 }));
}
test "launcher readiness comes from the control transport, attachment from a worker epoch" {
    const a = testing.allocator;
    var worker = try pairOf(a);
    defer worker.deinit();
    Client.rebuild(worker.client);
    try std.testing.expect(Client.snapshotFn(@ptrCast(worker.client)).available);
    try std.testing.expect(Client.snapshotFn(@ptrCast(worker.client)).attached);

    var launcher = try connectClientWithControl(a);
    defer launcher.deinit();
    Client.rebuild(launcher.client);
    // A --connect launcher may serve its first explicit submit without owning a
    // session yet; that is not the same thing as being attached to one.
    try std.testing.expect(Client.snapshotFn(@ptrCast(launcher.client)).available);
    try std.testing.expect(!Client.snapshotFn(@ptrCast(launcher.client)).attached);
    try std.testing.expectEqual(@as(u64, 0), Client.snapshotFn(@ptrCast(launcher.client)).control_epoch);

    Client.closeControl(launcher.client);
    Client.rebuild(launcher.client);
    try std.testing.expect(!Client.snapshotFn(@ptrCast(launcher.client)).available);
    try std.testing.expect(!Client.currentFn(@ptrCast(launcher.client)).available);
}
test "a foreground or attach launcher may start its own worker without a connection" {
    const a = testing.allocator;
    // A takeover leaves no worker transport and no daemon control behind.
    var pair = try pairOf(a);
    defer pair.deinit();
    Client.loseView(pair.client);
    try std.testing.expect(pair.client.conn == null and pair.client.control == null);
    try std.testing.expect(pair.client.mode == .foreground);
    try std.testing.expect(Client.snapshotFn(@ptrCast(pair.client)).available);
    try std.testing.expect(!Client.snapshotFn(@ptrCast(pair.client)).attached);
    try std.testing.expectEqual(@as(u64, 0), Client.snapshotFn(@ptrCast(pair.client)).control_epoch);

    pair.client.mode = .attach;
    Client.rebuild(pair.client);
    try std.testing.expect(Client.snapshotFn(@ptrCast(pair.client)).available);

    // --connect has no worker of its own: the control socket is the capability.
    var connect = try connectClientWithControl(a);
    defer connect.deinit();
    Client.closeControl(connect.client);
    Client.rebuild(connect.client);
    try std.testing.expect(!Client.snapshotFn(@ptrCast(connect.client)).available);
    try std.testing.expect(connect.client.conn == null and connect.client.control == null);
}
test "a launcher submission asks for a session instead of refusing the draft" {
    const a = testing.allocator;
    var pair = try connectClientWithControl(a);
    defer pair.deinit();
    const client = pair.client;

    // Epoch 0 with no connection is the launcher: the create request is really
    // sent. A reply without the session identity stops as a protocol error, so
    // the draft was not refused up front as a lost controller.
    try pair.reply(1, "\"endpoint\":\"/nonexistent/thin/worker.sock\"");
    try std.testing.expectError(error.ProtocolError, Client.submitFn(@ptrCast(client), 0, .prompt, "hello"));
    const create = try readFrameJson(&pair, a);
    defer create.deinit();
    try std.testing.expectEqualStrings("create", create.value.object.get("op").?.string);
    try std.testing.expectEqualStrings(client.launcher, create.value.object.get("project").?.string);
    try std.testing.expect(client.conn == null and client.epoch == 0);
    try std.testing.expect(client.receipt == null);
}
test "a live view without control refuses submissions without sending anything" {
    const a = testing.allocator;
    var pair = try pairOf(a);
    defer pair.deinit();
    try std.testing.expectError(error.StaleControl, Client.submitFn(@ptrCast(pair.client), 0, .prompt, "hello"));
    try expectNoFrame(&pair);
    try std.testing.expect(pair.client.receipt == null);
}
test "a replaced controller epoch drops the view and returns to the launcher" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;

    try pair.reply(1, "\"snapshot\":{\"background\":{\"active_count\":0},\"session\":\"0123456789abcdef0123456789abcdef\",\"epoch\":99,\"attached\":true,\"busy\":true,\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}");
    client.refreshSnapshot();
    // Only this view is released: no shutdown, no cancel, no epoch-0 connection
    // that would make every later input stale forever.
    try std.testing.expect(client.conn == null);
    try std.testing.expectEqual(@as(u64, 0), client.epoch);
    try std.testing.expect(client.session == null);
    try std.testing.expect(!Client.snapshotFn(@ptrCast(client)).attached);
    try std.testing.expect(!Client.snapshotFn(@ptrCast(client)).busy);
    // A foreground console keeps the capability to start its own worker, so the
    // next explicit input is not refused as a lost view.
    try std.testing.expect(Client.snapshotFn(@ptrCast(client)).available);
    // Only the snapshot request was written, then this view's socket closed:
    // no shutdown, detach or cancel ever reached the owner.
    const probe_frame = try readFrameJson(&pair, a);
    defer probe_frame.deinit();
    try std.testing.expectEqualStrings("snapshot", probe_frame.value.object.get("op").?.string);
    if (try pair.server.readFrame(.{ .io = std.testing.io, .timeout_ms = 100 })) |extra| {
        defer a.free(extra);
        return error.TestUnexpectedResult;
    }
}
test "a real takeover (owner reports epoch 0) returns to the launcher without touching owned work" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    const owned_id: ids.Id = "fedcbafedcbafedcbafedcbafedcbafe".*;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;
    // This launcher also owns a worker of its own; losing the console of the
    // attached session must not stop, close or unpublish that owned worker.
    try client.published.append(a, .{
        .id = owned_id,
        .project = try a.dupe(u8, client.launcher),
        .endpoint = try a.dupe(u8, "/nonexistent/thin/owned.sock"),
    });

    // The service never hands another console's epoch to the loser: a revoked
    // controller sees `epoch: 0` (still busy, still running).
    try pair.reply(1, "\"snapshot\":{\"background\":{\"active_count\":0},\"session\":\"0123456789abcdef0123456789abcdef\",\"epoch\":0,\"attached\":false,\"busy\":true,\"memory\":{\"enabled\":false,\"revision\":0,\"active\":null,\"queued_count\":0,\"last_terminal\":null}}");
    client.refreshSnapshot();

    const published = Client.snapshotFn(@ptrCast(client));
    try std.testing.expect(client.conn == null);
    try std.testing.expectEqual(@as(u64, 0), client.epoch);
    try std.testing.expect(client.session == null);
    try std.testing.expect(published.session_id == null);
    try std.testing.expectEqual(@as(u64, 0), published.control_epoch);
    try std.testing.expect(!published.attached);
    try std.testing.expect(!published.busy);
    // Back at the launcher: the next input creates a new session there.
    try std.testing.expect(Client.currentFn(@ptrCast(client)).session_id == null);
    // Owned work survives: the locator is kept and the launcher still owns it.
    try std.testing.expect(Client.ownsAnyWorker(client));
    try std.testing.expect(Client.ownsSession(client, owned_id));
    try std.testing.expectEqual(@as(usize, 1), client.published.items.len);
    try std.testing.expectEqualStrings("/nonexistent/thin/owned.sock", client.published.items[0].endpoint);

    // Exactly the snapshot probe reached the owner, then this view's socket
    // closed: no shutdown, close, detach or cancel frame follows.
    const probe_frame = try readFrameJson(&pair, a);
    defer probe_frame.deinit();
    try std.testing.expectEqualStrings("snapshot", probe_frame.value.object.get("op").?.string);
    if (try pair.server.readFrame(.{ .io = std.testing.io, .timeout_ms = 100 })) |extra| {
        defer a.free(extra);
        return error.TestUnexpectedResult;
    }
}
test "resuming the attached session is a no-op with a caller-owned notice" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;
    client.view_project = try a.dupe(u8, client.launcher);
    const revision = client.publication_revision;
    var caller = testing.FailingAllocator.init(a, .{});
    {
        var outcome = try Client.manageFn(@ptrCast(client), caller.allocator(), .{ .@"resume" = &session_id });
        defer outcome.deinit(caller.allocator());
        try testing.expectEqualStrings("Already attached", outcome.notice.?);
        try testing.expect(!outcome.switched);
        try testing.expectEqual(@as(usize, 1), caller.allocations);
        try testing.expectEqual(@as(usize, "Already attached".len), caller.allocated_bytes);
    }
    try testing.expectEqual(caller.allocated_bytes, caller.freed_bytes);
    try testing.expect(client.conn != null);
    try testing.expectEqualDeep(@as(?ids.Id, session_id), client.session);
    try testing.expectEqual(@as(u64, 5), client.epoch);
    try testing.expectEqual(revision, client.publication_revision);
    try testing.expect(client.workers == null and client.reg == null and client.control == null);
    try expectNoFrame(&pair);
}
test "resume notice allocation failure precedes local restore and daemon create" {
    const a = testing.allocator;
    const current_id: ids.Id = "fedcbafedcbafedcbafedcbafedcbafe".*;
    const requested_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    for ([_]bool{ false, true }) |daemon| {
        var pair = if (daemon) try connectClientWithControl(a) else try pairOf(a);
        defer pair.deinit();
        const client = pair.client;
        if (!daemon) client.session = current_id;
        const session = client.session;
        const epoch = client.epoch;
        const revision = client.publication_revision;
        // A regression may reach the stub control socket, but must never
        // start a process or wait for a real daemon/API response.
        if (daemon) try pair.replyError(1, "busy");
        var caller = testing.FailingAllocator.init(a, .{ .fail_index = 0 });
        try testing.expectError(error.OutOfMemory, Client.manageFn(@ptrCast(client), caller.allocator(), .{ .@"resume" = &requested_id }));
        try testing.expect(caller.has_induced_failure);
        try testing.expectEqual(caller.allocated_bytes, caller.freed_bytes);
        try testing.expectEqualDeep(session, client.session);
        try testing.expectEqual(epoch, client.epoch);
        try testing.expectEqual(revision, client.publication_revision);
        try testing.expectEqual(!daemon, client.conn != null);
        try testing.expectEqual(daemon, client.control != null);
        try testing.expect(client.workers == null and client.reg == null);
        try expectNoFrame(&pair);
    }
}
test "closing the attached session carries its control epoch" {
    const a = testing.allocator;
    const session_id: ids.Id = "0123456789abcdef0123456789abcdef".*;
    var pair = try pairOf(a);
    defer pair.deinit();
    const client = pair.client;
    client.session = session_id;

    // The owner refuses a busy task without force and the view survives.
    try pair.reply(1, "\"accepted\":false");
    try std.testing.expectError(error.Busy, Client.manageFn(@ptrCast(client), a, .{ .close = .{ .id = &session_id, .force = false } }));
    const refused = try readFrameJson(&pair, a);
    defer refused.deinit();
    try std.testing.expectEqualStrings("close", refused.value.object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 5), refused.value.object.get("epoch").?.integer);
    try std.testing.expect(!refused.value.object.get("force").?.bool);
    try std.testing.expect(client.conn != null and client.session != null);

    // Accepted: the owner saved and exited, so this view is gone.
    try pair.reply(2, "\"accepted\":true");
    var outcome = try Client.manageFn(@ptrCast(client), a, .{ .close = .{ .id = &session_id, .force = true } });
    defer outcome.deinit(a);
    try std.testing.expect(client.conn == null and client.session == null);
    try std.testing.expect(outcome.notice != null);
}
test "closing an owned session outside this view demands --force" {
    const a = testing.allocator;
    var fixture = try AttachEnv.init(a);
    defer fixture.deinit(a);
    const client = try Client.init(a, testing.io, &fixture.env, .connect, fixture.project, fixture.home);
    defer client.deinit();
    // No view and no connection: this launcher only owns a detached worker.
    const owned_id: ids.Id = "fedcbafedcbafedcbafedcbafedcbafe".*;
    try client.published.append(a, .{
        .id = owned_id,
        .project = try a.dupe(u8, fixture.project),
        .endpoint = try a.dupe(u8, "/nonexistent/thin/owned.sock"),
    });

    var outcome = try Client.manageFn(@ptrCast(client), a, .{ .close = .{ .id = &owned_id, .force = false } });
    defer outcome.deinit(a);
    try std.testing.expectEqualStrings(
        "Closing an owned session outside this view requires /close fedcbafedcbafedcbafedcbafedcbafe --force",
        outcome.notice.?,
    );
    // Refusal only: the locator is kept and no registry, worker manager or
    // control socket was opened, so nothing observed or stopped that process.
    try std.testing.expect(client.conn == null);
    try std.testing.expect(client.session == null);
    try std.testing.expect(client.workers == null);
    try std.testing.expect(client.control == null);
    try std.testing.expectEqual(@as(usize, 1), client.published.items.len);
    try std.testing.expect(Client.ownsSession(client, owned_id));
}
test "a daemon-owned session close demands --force before any control request" {
    const a = testing.allocator;
    var fixture = try AttachEnv.init(a);
    defer fixture.deinit(a);

    const client = try Client.init(a, testing.io, &fixture.env, .connect, fixture.project, fixture.home);
    defer client.deinit();
    var fds: [2]std.c.fd_t = undefined;
    if (testSocketPair(&fds) != 0) return error.SocketPairFailed;
    const peer: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
    client.control = unix.Connection.init(a, fds[0], peer);
    var server = unix.Connection.init(a, fds[1], peer);
    defer server.close();
    client.reg = try Registry.init(a, testing.io, &fixture.env);

    // An owner-managed record this launcher never published: only the daemon
    // can stop it, so a busy task cannot be ruled out from here.
    const id: ids.Id = "00112233445566778899aabbccddeeff".*;
    const endpoint = try std.fmt.allocPrint(a, "{s}/workers/0011223344556677.sock", .{client.reg.?.runtime.path});
    defer a.free(endpoint);
    try client.reg.?.register(.{
        .id = id,
        .project = fixture.project,
        .endpoint = endpoint,
        .owner = .daemon,
        .owner_instance = "0011223344556677",
        .state = "running",
        .pid = @intCast(std.c.getpid()),
        .generation = 1,
    });

    var outcome = try Client.manageFn(@ptrCast(client), a, .{ .close = .{ .id = &id, .force = false } });
    defer outcome.deinit(a);
    try std.testing.expectEqualStrings(
        "Closing an owned session outside this view requires /close 00112233445566778899aabbccddeeff --force",
        outcome.notice.?,
    );
    // No `close` frame reached the daemon and no worker manager was created:
    // the refusal stops nothing and only asks for the confirmation.
    try expectNoFrameOn(&server);
    try std.testing.expect(client.workers == null);
    try std.testing.expect(client.session == null and client.conn == null);
    var kept = (try client.reg.?.resolve(a, id, fixture.project)) orelse return error.TestExpectedRecord;
    defer registry.freeRecord(a, &kept);
    try std.testing.expectEqualStrings(endpoint, kept.endpoint);
}
test "resume live owner allocation failure and occupied controller preserve the old view" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try AttachEnv.init(a);
    defer fixture.deinit(a);
    const client = try Client.init(a, io, &fixture.env, .connect, fixture.project, fixture.home);
    defer client.deinit();
    const current: ids.Id = "fedcbafedcbafedcbafedcbafedcbafe".*;
    const target: ids.Id = "abcdefabcdefabcdefabcdefabcdefab".*;
    const peer: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
    var old_fds: [2]std.c.fd_t = undefined;
    if (testSocketPair(&old_fds) != 0) return error.SocketPairFailed;
    client.conn = unix.Connection.init(a, old_fds[0], peer);
    var old_server = unix.Connection.init(a, old_fds[1], peer);
    defer old_server.close();
    client.session = current;
    client.epoch = 5;
    var control_fds: [2]std.c.fd_t = undefined;
    if (testSocketPair(&control_fds) != 0) return error.SocketPairFailed;
    client.control = unix.Connection.init(a, control_fds[0], peer);
    var control_server = unix.Connection.init(a, control_fds[1], peer);
    defer control_server.close();

    // Prepopulate only an owned registry; the client must not open it until
    // after its caller-owned notice has been allocated successfully.
    var reg = try Registry.init(a, io, &fixture.env);
    defer reg.deinit();
    var workers_dir = try unix.Directory.resolveUnder(a, reg.runtime.path, "workers", client.uid);
    defer workers_dir.deinit();
    var listener = try unix.Listener.bind(a, &workers_dir, "0123456789abcdef.sock", .{});
    defer listener.deinit();
    try reg.register(.{
        .id = target,
        .project = fixture.project,
        .endpoint = listener.path,
        .owner = .daemon,
        .owner_instance = "0123456789abcdef",
        .state = "running",
        .pid = @intCast(std.c.getpid()),
        .generation = 1,
    });
    const old_fd = client.conn.?.fd;
    const revision = client.publication_revision;
    var failing = testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, client.manageResume(failing.allocator(), &target));
    try testing.expect(failing.has_induced_failure and client.reg == null);
    try testing.expectEqual(old_fd, client.conn.?.fd);
    try testing.expectEqual(current, client.session.?);
    try testing.expectEqual(@as(u64, 5), client.epoch);
    try testing.expectEqual(revision, client.publication_revision);
    var quiet = [_]std.c.pollfd{.{ .fd = listener.fd, .events = std.c.POLL.IN, .revents = 0 }};
    try testing.expectEqual(@as(c_int, 0), std.c.poll(&quiet, 1, 40));
    try expectNoFrameOn(&old_server);
    try expectNoFrameOn(&control_server);

    var task = try std.Io.concurrent(io, busyResumePeer, .{ a, io, &listener, target });
    var pending = true;
    defer if (pending) {
        task.cancel(io) catch {};
    };
    try testing.expectError(error.Busy, client.manageResume(a, &target));
    const result = task.await(io);
    pending = false;
    try result;
    try testing.expectEqual(old_fd, client.conn.?.fd);
    try testing.expectEqual(current, client.session.?);
    try testing.expectEqual(@as(u64, 5), client.epoch);
    try testing.expectEqual(revision, client.publication_revision);
    try testing.expect(client.workers == null);
    try testing.expectEqual(@as(c_int, 0), std.c.poll(&quiet, 1, 40));
    try expectNoFrameOn(&old_server);
    try expectNoFrameOn(&control_server);
}
test "attach resumes a confirmed-dead endpoint only with a complete checkpoint" {
    const a = testing.allocator;
    var fixture = try AttachEnv.init(a);
    defer fixture.deinit(a);

    const client = try Client.init(a, testing.io, &fixture.env, .connect, fixture.project, fixture.home);
    defer client.deinit();
    var fds: [2]std.c.fd_t = undefined;
    if (testSocketPair(&fds) != 0) return error.SocketPairFailed;
    const peer: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
    client.control = unix.Connection.init(a, fds[0], peer);
    var server = unix.Connection.init(a, fds[1], peer);
    defer server.close();
    client.reg = try Registry.init(a, testing.io, &fixture.env);

    const id: ids.Id = "abcdefabcdefabcdefabcdefabcdefab".*;
    const record: registry.Record = .{
        .id = id,
        .project = fixture.project,
        .endpoint = try std.fmt.allocPrint(a, "{s}/workers/0123456789abcdef.sock", .{client.reg.?.runtime.path}),
        .owner = .daemon,
        .owner_instance = "0123456789abcdef",
        .state = "running",
        .pid = @intCast(std.c.getpid()),
        .generation = 1,
    };
    defer a.free(@constCast(record.endpoint));
    try client.reg.?.register(record);

    // Registered endpoint that no longer exists and no checkpoint: nothing may
    // start, and no owner is asked to create one.
    try std.testing.expectError(error.SessionNotFound, Client.attachSession(client, id, false));
    try std.testing.expectError(error.SessionNotFound, Client.manageResume(client, a, &id));
    try expectNoFrameOn(&server);

    // A complete checkpoint makes the same history resumable. In --connect the
    // daemon creates the replacement worker; it is never a local process.
    var name_buf: [128]u8 = undefined;
    const checkpoint = try std.fmt.bufPrint(&name_buf, "project/.thin/sessions/{s}.session", .{id});
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = checkpoint, .data = "complete checkpoint" });
    const create_reply = try std.fmt.allocPrint(a, "\"session\":\"{s}\",\"endpoint\":\"/nonexistent/thin/worker.sock\"", .{id});
    defer a.free(create_reply);
    const create_frame = try std.fmt.allocPrint(a, "{{\"v\":{d},\"id\":1,\"ok\":true,{s}}}", .{ protocol.version, create_reply });
    defer a.free(create_frame);
    try server.writeFrame(create_frame, .{ .io = std.testing.io, .timeout_ms = 5_000 });
    // The published endpoint does not exist, so the candidate attach fails; the
    // control request that asked for the resume is what this test proves.
    try std.testing.expectError(error.Transport, Client.attachSession(client, id, false));
    const create = try readJsonFrame(&server, a);
    defer create.deinit();
    try std.testing.expectEqualStrings("create", create.value.object.get("op").?.string);
    try std.testing.expectEqualStrings(fixture.project, create.value.object.get("project").?.string);
    try std.testing.expectEqualStrings(&id, create.value.object.get("resume").?.string);
}
test "an unreachable-but-present endpoint is never treated as dead" {
    const a = testing.allocator;
    var fixture = try AttachEnv.init(a);
    defer fixture.deinit(a);

    const client = try Client.init(a, testing.io, &fixture.env, .connect, fixture.project, fixture.home);
    defer client.deinit();
    var fds: [2]std.c.fd_t = undefined;
    if (testSocketPair(&fds) != 0) return error.SocketPairFailed;
    const peer: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
    client.control = unix.Connection.init(a, fds[0], peer);
    var server = unix.Connection.init(a, fds[1], peer);
    defer server.close();
    client.reg = try Registry.init(a, testing.io, &fixture.env);

    const id: ids.Id = "fedcbafedcbafedcbafedcbafedcbafe".*;
    const endpoint = try std.fmt.allocPrint(a, "{s}/workers/fedcba9876543210.sock", .{client.reg.?.runtime.path});
    defer a.free(endpoint);
    // The endpoint path exists but is a plain file, not a socket: that is an
    // unreadable owner, never proof that the history is free.
    _ = try fixture.tmp.dir.createDirPathStatus(testing.io, "runtime/thin/workers", .fromMode(0o700));
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = endpoint, .data = "not a socket" });
    try client.reg.?.register(.{
        .id = id,
        .project = fixture.project,
        .endpoint = endpoint,
        .owner = .daemon,
        .owner_instance = "fedcba9876543210",
        .state = "running",
        .pid = @intCast(std.c.getpid()),
        .generation = 1,
    });
    var name_buf: [128]u8 = undefined;
    const checkpoint = try std.fmt.bufPrint(&name_buf, "project/.thin/sessions/{s}.session", .{id});
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = checkpoint, .data = "complete checkpoint" });

    try std.testing.expectError(error.Unavailable, Client.attachSession(client, id, false));
    try std.testing.expectError(error.Unavailable, Client.manageResume(client, a, &id));
    try expectNoFrameOn(&server);
    try std.testing.expect(client.conn == null);
}
test "resume never resolves another project's registry owner" {
    const a = testing.allocator;
    var fixture = try AttachEnv.init(a);
    defer fixture.deinit(a);
    const client = try Client.init(a, testing.io, &fixture.env, .connect, fixture.project, fixture.home);
    defer client.deinit();
    client.reg = try Registry.init(a, testing.io, &fixture.env);
    const id: ids.Id = "abcdefabcdefabcdefabcdefabcdefab".*;
    const endpoint = try std.fmt.allocPrint(a, "{s}/workers/0123456789abcdef.sock", .{client.reg.?.runtime.path});
    defer a.free(endpoint);
    const other = try std.fmt.allocPrint(a, "{s}/other", .{fixture.home});
    defer a.free(other);
    try client.reg.?.register(.{
        .id = id,
        .project = other,
        .endpoint = endpoint,
        .owner = .daemon,
        .owner_instance = "0123456789abcdef",
        .state = "running",
        .pid = @intCast(std.c.getpid()),
        .generation = 1,
    });
    try testing.expectError(error.SessionNotFound, client.manageResume(a, &id));
    try testing.expect(client.conn == null and client.session == null);
}
test "close via endpoint opens no watch" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try AttachEnv.init(a);
    defer fixture.deinit(a);
    const client = try Client.init(a, io, &fixture.env, .foreground, fixture.project, fixture.home);
    defer client.deinit();
    var dir = try unix.Directory.resolveUnder(a, fixture.runtime, "close", client.uid);
    defer dir.deinit();
    var listener = try unix.Listener.bind(a, &dir, "worker.sock", .{});
    defer listener.deinit();
    const id: ids.Id = "abcdefabcdefabcdefabcdefabcdefab".*;
    const record: registry.Record = .{ .id = id, .project = fixture.project, .endpoint = listener.path, .owner = .foreground, .owner_instance = "0123456789abcdef", .state = "running", .pid = @intCast(std.c.getpid()), .generation = 1 };
    var task = try std.Io.concurrent(io, closeOnlyPeer, .{ a, io, &listener, id });
    var pending = true;
    defer if (pending) task.cancel(io) catch {};
    try client.closeViaEndpoint(&record, id, true);
    const result = task.await(io);
    pending = false;
    try result;
    var quiet = [_]std.c.pollfd{.{ .fd = listener.fd, .events = std.c.POLL.IN, .revents = 0 }};
    try testing.expectEqual(@as(c_int, 0), std.c.poll(&quiet, 1, 40));
    try testing.expect(client.stream == null and client.conn == null);
}
test "record identity and watch admission failures never replace the current view or create" {
    const a = testing.allocator;
    const io = testing.io;
    for ([_]CandidatePeerCase{ .record_pid, .hello_pid, .owner, .watch_gone, .watch_eof, .watch_reject, .watch_timeout, .snapshot, .snapshot_identity, .snapshot_project, .snapshot_epoch, .baseline_epoch, .baseline }) |behavior| {
        var fixture = try AttachEnv.init(a);
        defer fixture.deinit(a);
        const client = try Client.init(a, io, &fixture.env, .connect, fixture.project, fixture.home);
        defer client.deinit();
        client.candidate_timeout_ms = 250;
        const target: ids.Id = "abcdefabcdefabcdefabcdefabcdefab".*;
        const old_id: ids.Id = "fedcbafedcbafedcbafedcbafedcbafe".*;
        const creds: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
        var old_fds: [2]std.c.fd_t = undefined;
        var control_fds: [2]std.c.fd_t = undefined;
        if (testSocketPair(&old_fds) != 0 or testSocketPair(&control_fds) != 0) return error.SocketPairFailed;
        client.conn = unix.Connection.init(a, old_fds[0], creds);
        var old_peer = unix.Connection.init(a, old_fds[1], creds);
        defer old_peer.close();
        client.control = unix.Connection.init(a, control_fds[0], creds);
        var control_peer = unix.Connection.init(a, control_fds[1], creds);
        defer control_peer.close();
        client.session = old_id;
        client.epoch = 5;
        client.cursor = 23;
        client.cache.valid = true;
        client.cache.task = 42;
        try client.pushEvent(.{ .string = "{\"t\":\"text\",\"v\":\"old history\"}" });
        try checkpointFor(&fixture, target);
        client.reg = try Registry.init(a, io, &fixture.env);
        var workers_dir = try unix.Directory.resolveUnder(a, client.reg.?.runtime.path, "workers", client.uid);
        defer workers_dir.deinit();
        var listener = try unix.Listener.bind(a, &workers_dir, "0123456789abcdef.sock", .{});
        defer listener.deinit();
        const real_pid: u32 = @intCast(std.c.getpid());
        try client.reg.?.register(.{
            .id = target,
            .project = fixture.project,
            .endpoint = listener.path,
            .owner = .daemon,
            .owner_instance = "0123456789abcdef",
            .state = "running",
            .pid = if (behavior == .record_pid) real_pid + 1 else real_pid,
            .generation = 1,
        });
        const old_fd = client.conn.?.fd;
        const revision = client.publication_revision;
        var task = try std.Io.concurrent(io, candidatePeer, .{ a, io, &listener, target, fixture.project, cli.WorkerOwner.daemon, behavior });
        var pending = true;
        defer if (pending) task.cancel(io) catch {};
        try testing.expectError(error.Unavailable, client.manageResume(a, &target));
        const result = task.await(io);
        pending = false;
        try result;
        try testing.expectEqual(old_fd, client.conn.?.fd);
        try testing.expectEqual(old_id, client.session.?);
        try testing.expectEqual(@as(u64, 5), client.epoch);
        try testing.expectEqual(@as(u64, 23), client.cursor);
        try testing.expect(client.cache.valid and client.cache.task == 42);
        try testing.expectEqual(@as(usize, 1), client.pending.items.len);
        try testing.expectEqual(revision, client.publication_revision);
        try testing.expect(client.workers == null);
        try expectNoFrameOn(&old_peer);
        try expectNoFrameOn(&control_peer); // zero create
        var quiet = [_]std.c.pollfd{.{ .fd = listener.fd, .events = std.c.POLL.IN, .revents = 0 }};
        try testing.expectEqual(@as(c_int, 0), std.c.poll(&quiet, 1, 40));
    }
}
test "malformed registry with live owner and checkpoint does not authorize a restore" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try AttachEnv.init(a);
    defer fixture.deinit(a);
    const client = try Client.init(a, io, &fixture.env, .connect, fixture.project, fixture.home);
    defer client.deinit();
    client.reg = try Registry.init(a, io, &fixture.env);
    const target: ids.Id = "abcdefabcdefabcdefabcdefabcdefab".*;
    try checkpointFor(&fixture, target);
    var workers_dir = try unix.Directory.resolveUnder(a, client.reg.?.runtime.path, "workers", client.uid);
    defer workers_dir.deinit();
    var listener = try unix.Listener.bind(a, &workers_dir, "0123456789abcdef.sock", .{});
    defer listener.deinit();
    try client.reg.?.register(.{ .id = target, .project = fixture.project, .endpoint = listener.path, .owner = .daemon, .owner_instance = "0123456789abcdef", .state = "running", .pid = @intCast(std.c.getpid()), .generation = 1 });
    const key = registry.projectKey(fixture.project);
    const record_path = try std.fmt.allocPrint(a, "{s}/.thin/session-index/{s}/{s}.json", .{ fixture.home, key, target });
    defer a.free(record_path);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = record_path, .data = "{broken" });
    const creds: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
    var old_fds: [2]std.c.fd_t = undefined;
    var control_fds: [2]std.c.fd_t = undefined;
    if (testSocketPair(&old_fds) != 0 or testSocketPair(&control_fds) != 0) return error.SocketPairFailed;
    client.conn = unix.Connection.init(a, old_fds[0], creds);
    var old_peer = unix.Connection.init(a, old_fds[1], creds);
    defer old_peer.close();
    client.control = unix.Connection.init(a, control_fds[0], creds);
    var control_peer = unix.Connection.init(a, control_fds[1], creds);
    defer control_peer.close();
    const old_id: ids.Id = "fedcbafedcbafedcbafedcbafedcbafe".*;
    client.session = old_id;
    client.epoch = 5;
    const old_fd = client.conn.?.fd;
    var stop: p.Cancellation = .{};
    var contacted = std.atomic.Value(bool).init(false);
    var owner = try std.Io.concurrent(io, registryOwnerPeer, .{ a, io, &listener, target, &stop, &contacted });
    var owner_pending = true;
    defer if (owner_pending) {
        stop.cancel();
        owner.cancel(io) catch {};
    };
    const result = client.manageResume(a, &target);
    stop.cancel();
    const owner_result = owner.await(io);
    owner_pending = false;
    try owner_result;
    try testing.expect(!contacted.load(.acquire));
    if (result) |outcome| {
        var unexpected = outcome;
        unexpected.deinit(a);
        return error.TestUnexpectedResult;
    } else |_| {}
    try testing.expectEqual(old_fd, client.conn.?.fd);
    try testing.expectEqual(old_id, client.session.?);
    try testing.expectEqual(@as(u64, 5), client.epoch);
    try expectNoFrameOn(&old_peer);
    try expectNoFrameOn(&control_peer);
    var quiet = [_]std.c.pollfd{.{ .fd = listener.fd, .events = std.c.POLL.IN, .revents = 0 }};
    try testing.expectEqual(@as(c_int, 0), std.c.poll(&quiet, 1, 40));
}
test "resume selects launcher project when attached to another project's same id" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try AttachEnv.init(a);
    defer fixture.deinit(a);
    try fixture.tmp.dir.createDir(io, "other", .fromMode(0o700));
    const other = try std.fmt.allocPrint(a, "{s}/../other", .{fixture.project});
    defer a.free(other);
    // Registry projects are canonical, as real workers publish them.
    const project_b = try std.Io.Dir.cwd().realPathFileAlloc(io, other, a);
    defer a.free(project_b);
    const client = try Client.init(a, io, &fixture.env, .connect, fixture.project, fixture.home);
    var client_live = true;
    defer if (client_live) client.deinit();
    client.reg = try Registry.init(a, io, &fixture.env);
    const id: ids.Id = "abcdefabcdefabcdefabcdefabcdefab".*;
    try checkpointFor(&fixture, id);
    var workers_dir = try unix.Directory.resolveUnder(a, client.reg.?.runtime.path, "workers", client.uid);
    defer workers_dir.deinit();
    var a_listener = try unix.Listener.bind(a, &workers_dir, "0123456789abcdef.sock", .{});
    defer a_listener.deinit();
    var b_listener = try unix.Listener.bind(a, &workers_dir, "fedcba9876543210.sock", .{});
    defer b_listener.deinit();
    try client.reg.?.register(.{ .id = id, .project = project_b, .endpoint = b_listener.path, .owner = .foreground, .owner_instance = "fedcba9876543210", .state = "running", .pid = @intCast(std.c.getpid()), .generation = 1 });
    var b_task = try std.Io.concurrent(io, candidatePeer, .{ a, io, &b_listener, id, project_b, cli.WorkerOwner.foreground, CandidatePeerCase.good });
    var b_pending = true;
    defer if (b_pending) b_task.cancel(io) catch {};
    var attached = try client.attachSession(id, false);
    defer attached.deinit(a);
    try testing.expect(attached.switched);
    try testing.expectEqualStrings(project_b, client.view_project.?);
    try testing.expectEqual(id, client.session.?);
    const creds: unix.Credentials = .{ .pid = 0, .uid = client.uid, .gid = @intCast(std.c.getgid()) };
    var fds: [2]std.c.fd_t = undefined;
    if (testSocketPair(&fds) != 0) return error.SocketPairFailed;
    client.control = unix.Connection.init(a, fds[0], creds);
    var daemon_peer = unix.Connection.init(a, fds[1], creds);
    defer daemon_peer.close();
    var a_task = try std.Io.concurrent(io, candidatePeer, .{ a, io, &a_listener, id, fixture.project, cli.WorkerOwner.daemon, CandidatePeerCase.good });
    var a_pending = true;
    defer if (a_pending) a_task.cancel(io) catch {};
    var create_task = try std.Io.concurrent(io, createResumePeer, .{ a, io, &daemon_peer, id, fixture.project, a_listener.path });
    var create_pending = true;
    defer if (create_pending) create_task.cancel(io) catch {};
    var resumed = try client.manageResume(a, &id);
    defer resumed.deinit(a);
    try testing.expect(resumed.switched);
    try testing.expectEqualStrings(session_client.restored_notice, resumed.notice.?);
    try testing.expectEqualStrings(fixture.project, client.view_project.?);
    try testing.expectEqual(id, client.session.?);
    const create_result = create_task.await(io);
    create_pending = false;
    try create_result;
    const b_result = b_task.await(io);
    b_pending = false;
    try b_result;
    // The candidate's copied validation frames were not consumed or ACKed.
    try client.pumpStream();
    try client.pumpStream();
    try testing.expect(!client.need_history);
    try testing.expectEqual(@as(usize, 1), client.pending.items.len);
    try testing.expectEqualStrings("initial history", client.pending.items[0].event.text);
    try testing.expect(client.pending.items[0].history_replay);
    try expectNoFrameOn(&daemon_peer);
    client.deinit();
    client_live = false;
    const a_result = a_task.await(io);
    a_pending = false;
    try a_result;
}
