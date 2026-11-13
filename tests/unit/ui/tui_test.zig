test "restored assistant keeps a bounded canonical mirror for a large static source" {
    const a = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "HEADMARK\\n");
    for (0..9000) |_| try source.appendSlice(a, "0123456789abcdefghijklmnopqrstuv\\n");
    try source.appendSlice(a, "TAILMARK\\x1b[2J中文");
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try replayMessages(&ui, std.testing.allocator, &.{.{ .role = .assistant, .blocks = &.{.{ .text = source.items }} }});
    var found = false;
    for (ui.records.items) |*record| {
        if (record.kind != .assistant) continue;
        found = true;
        // The transcript keeps a bounded mirror, never an unbounded copy.
        try std.testing.expect(record.mirror_full and !record.clipped);
        try std.testing.expectEqual(@as(usize, canonical_mirror_limit), record.body.items.len);
        try std.testing.expect(std.mem.startsWith(u8, record.body.items, source.items[0..canonical_mirror_limit]));
        try record.layout(a, 80);
        try std.testing.expect(record.lines.len != 0);
        try std.testing.expect(std.mem.indexOf(u8, record.lines[0], "HEADMARK") != null);
        for (record.lines) |line| try std.testing.expect(std.mem.indexOf(u8, line, "\\x1b[2J") == null);
    }
    try std.testing.expect(found);
}

fn staticMarkdownAllocationScenario(a: std.mem.Allocator) !void {
    const rendered = try markdown.render(a, "head **bold** 中文\x1b[2J\ntail", .{ .columns = 12, .max_lines = null });
    defer markdown.release(a, rendered);
    try std.testing.expect(!rendered.truncated);
}

test "static markdown allocation failures are transactional" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, staticMarkdownAllocationScenario, .{});
}

test "static plaintext preserves all rows beyond former limits" {
    const a = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "HEADMARK\n");
    for (0..9000) |_| try source.appendSlice(a, "0123456789abcdefghijklmnopqrstuv\n");
    try source.appendSlice(a, "TAILMARK\x1b[2J中文");
    const rendered = try markdown.render(a, source.items, .{ .columns = 80, .max_lines = null, .markdown = false, .ansi = false });
    defer markdown.release(a, rendered);
    try std.testing.expect(!rendered.truncated);
    try std.testing.expect(rendered.lines.len > 8192);
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[0], "HEADMARK") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[rendered.lines.len - 1], "TAILMARK") != null);
    for (rendered.lines) |line| try std.testing.expect(std.mem.indexOf(u8, line, "\x1b") == null);
}

test "stable pending pulses preserve native history and tail" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try seedPriorBottom(&screen);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    ui.busy = true;
    _ = try ui.inbox.enqueue(std.testing.allocator, .steering, "hold pending");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const history = screen.history_len;
    const height = ui.tail_height;
    ui.dirty = false;
    for (1..25) |i| {
        ui.clock_ms = @intCast(i * 80);
        ui.animate();
        try std.testing.expect(!ui.dirty);
        // Even if independent work requires a redraw, identical pending
        // snapshots must use owned rows and cannot advance native history.
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(history, screen.history_len);
        try std.testing.expectEqual(height, ui.tail_height);
        try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
    }
}
test "memory footer stays adjacent to wrapped composer after ACK" {
    const Fixture = struct {
        fn current(_: *anyopaque) Connection.State {
            return .{ .runtime = null, .available = true, .model = "fixture", .base_url = "", .memory = .{ .enabled = true, .active = .{ .id = 1, .phase = .extracting } } };
        }
    };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.current_fn = Fixture.current;
    ui.size = .{ .columns = 30, .rows = 12 };
    _ = try ui.add(.assistant, "body");
    _ = try ui.editor.insert("abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKL");
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 30, .rows = 12 };
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(ui.frame_composer_rows > 1);
    const status_row = screen.rows - ui.frame_composer_rows - 1;
    // The screen fixture maps each non-ASCII code point to one '~' cell.
    try std.testing.expectEqualStrings("M: ~", std.mem.trimEnd(u8, screen.grid[status_row][0..30], " "));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expected_status = try std.fmt.allocPrint(arena.allocator(), "M: {s}", .{activity.spinner(ui.clock_ms)});
    try std.testing.expectEqualStrings(expected_status, try ui.hint(arena.allocator(), ui.connection.current()));
    try std.testing.expectEqual(status_row + 1, try rowStartingWith(&screen, "(fixture) "));
    try std.testing.expectEqualStrings("", std.mem.trimEnd(u8, screen.grid[status_row - 1][0..30], " "));
    try std.testing.expectEqual(@as(usize, 1), screen.count("M: "));
    testAcknowledgeFullFrame(&ui);
    const history = screen.history_len;
    const records = ui.records.items.len;
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(history, screen.history_len);
    try std.testing.expectEqual(records, ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 1), screen.count("M: "));
}
test "long combined warning stays adjacent across acknowledged command menu cycles and wrapped input" {
    for ([_]usize{ 80, 120 }) |columns| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var fixture = SelectionFixture{ .settings_notice = "Saved thinking level not applied: model capabilities unknown" };
        defer fixture.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.connection = fixture.connection();
        ui.size.columns = columns;
        ui.notice = "Could not save thinking option; previous option kept";
        var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = columns };
        try seedPriorBottom(&screen);
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        ui.observeAdvisories();
        try ui.draw();
        try screen.replay(ui.frame);
        try expectLongWarningAdjacent(&screen, ui.frame_composer_rows, columns);
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
        var open_history: usize = 0;
        var closed_history: usize = 0;
        var open_height: usize = 0;
        var closed_height: usize = 0;
        for (0..2) |cycle| {
            try ui.parser.feed("/", sink);
            try ui.draw();
            try screen.replay(ui.frame);
            try std.testing.expect(ui.commandMenuVisible());
            try std.testing.expectEqual(@as(usize, 0), screen.count("Could not save thinking option"));
            try std.testing.expectEqual(@as(usize, 0), screen.count("Saved thinking level not applied"));
            try std.testing.expectEqual(screen.rows - ui.frame_composer_rows, try rowStartingWith(&screen, "(fixture-old) "));
            try std.testing.expectEqual(@as(usize, 1), screen.count("(fixture-old) "));
            try std.testing.expectEqual(screen.rows - 1, screen.row + ui.frame_cursor_rows_up);
            testAcknowledgeFullFrame(&ui);
            if (cycle == 0) {
                open_history = screen.history_len;
                open_height = ui.tail_height;
            } else {
                try std.testing.expectEqual(open_history, screen.history_len);
                try std.testing.expectEqual(open_height, ui.tail_height);
            }
            try ui.parser.feed("\x7f", sink);
            try ui.draw();
            try screen.replay(ui.frame);
            try expectLongWarningAdjacent(&screen, ui.frame_composer_rows, columns);
            try std.testing.expectEqual(screen.rows - 1, screen.row + ui.frame_cursor_rows_up);
            testAcknowledgeFullFrame(&ui);
            if (cycle == 0) {
                closed_history = screen.history_len;
                closed_height = ui.tail_height;
            } else {
                try std.testing.expectEqual(closed_history, screen.history_len);
                try std.testing.expectEqual(closed_height, ui.tail_height);
            }
        }
        const draft = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        try ui.parser.feed(draft, sink);
        try ui.draw();
        try std.testing.expect(ui.frame_composer_rows >= 2);
        try screen.replay(ui.frame);
        try expectLongWarningAdjacent(&screen, ui.frame_composer_rows, columns);
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
        const wrapped_history = screen.history_len;
        const wrapped_height = ui.tail_height;
        try ui.draw();
        try screen.replay(ui.frame);
        try expectLongWarningAdjacent(&screen, ui.frame_composer_rows, columns);
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(wrapped_history, screen.history_len);
        try std.testing.expectEqual(wrapped_height, ui.tail_height);
    }
}
test "bottom composer stays anchored across draft and menu frames" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.draw();
    try std.testing.expect(ui.menu_history == null and !ui.tail_bottom);
    try std.testing.expectEqual(screen.rows - ui.frame_height, ui.frame_menu_history.?.above.len);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(screen.rows - ui.tail_height, ui.menu_history.?.above.len);
    try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
    const history_before_menu = screen.history_len;
    try ui.parser.feed("/", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
    try std.testing.expectEqual(history_before_menu, screen.history_len);
    try Ui.key(&ui, .escape);
    try Ui.key(&ui, .clear);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
    try ui.parser.feed("a long draft that wraps across the composer and stays fixed on the bottom row of the terminal", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
    try Ui.key(&ui, .clear);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
}
test "idle Enter releases exactly one native row and redraw keeps the live draft" {
    for ([_]usize{ 80, 16 }) |columns| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.size.columns = columns;
        var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = columns };
        try seedPriorBottom(&screen);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        const history_start = screen.history_len;
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        // A read batch can contain several blank lines and then a new draft.
        try ui.parser.feed(" \t\r\r\rtyped", sink);
        try std.testing.expectEqual(@as(u16, 3), ui.idle_breaks);
        try std.testing.expectEqualStrings("typed", ui.editor.bytes.items);
        try ui.draw();
        try std.testing.expectEqual(@as(u16, 3), ui.frame_idle_breaks);
        try std.testing.expectEqual(@as(usize, 1), ui.frame_height);
        try screen.replay(ui.frame);
        try std.testing.expectEqual(history_start + 3, screen.history_len);
        try std.testing.expectEqual(@as(usize, 4), screen.count("?%>"));
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
        try std.testing.expect(ui.future == null and !ui.busy and ui.prompt == null);
        try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
        try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
        try std.testing.expect(ui.menu_history != null and ui.menu_history.?.above.len != 0);
        var expected_history = history_start + 3;
        for (0..3) |_| {
            const old_height = ui.tail_height;
            try ui.draw();
            // The narrow fixture now soft-wraps "typed". Its footer expansion
            // may grow native rows once, but cannot release another idle LF.
            try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
            expected_history += ui.frame_height -| old_height;
            try screen.replay(ui.frame);
            testAcknowledgeFullFrame(&ui);
            try std.testing.expectEqual(expected_history, screen.history_len);
            try std.testing.expectEqual(@as(usize, 4), screen.count("?%>"));
        }
        try std.testing.expectEqualStrings("typed", ui.editor.bytes.items);
        // A subsequent ordinary nonempty Enter still follows submit, not the
        // display-only path (this intentionally unconfigured fixture has no API).
        try Ui.key(&ui, .enter);
        try std.testing.expectEqualStrings("Not configured: use /login first", ui.notice);
        try std.testing.expectEqualStrings("", ui.editor.bytes.items);
        try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    }
}
test "idle Enter bounded stages retain more than one frame of line requests" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try seedPriorBottom(&screen);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const old_history = screen.history_len;
    for (0..300) |_| try Ui.key(&ui, .enter);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 256), ui.frame_idle_breaks);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(u16, 44), ui.idle_breaks);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 44), ui.frame_idle_breaks);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    try std.testing.expectEqual(old_history + 300, screen.history_len);
    try std.testing.expectEqual(@as(usize, 301), screen.count("?%>"));
}
test "idle Enter rejects paste queue permission and undrained bridge provenance" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[200~ \r\x1b[201~\r", sink);
    try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    ui.wipeEditor();
    bridge.outstanding = 1;
    try std.testing.expect(!ui.idleEnter());
    bridge.outstanding = 0;
    bridge.active = 1;
    try std.testing.expect(!ui.idleEnter());
    bridge.active = 0;
    bridge.pending = 1;
    try std.testing.expect(!ui.idleEnter());
    bridge.pending = null;
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .text = "not yet drained" }, &cancel);
    try Ui.key(&ui, .enter);
    try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    var item = bridge.pop().?;
    try std.testing.expect(!ui.idleEnter());
    item.deinit();
    ui.parser.batch_paste = false;
    ui.parser.pasted = false;
    ui.editor_pasted = false;
    try std.testing.expect(ui.idleEnter());
    ui.busy = true;
    try Ui.key(&ui, .enter);
    try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    ui.busy = false;
    ui.stop_open = true;
    try std.testing.expect(!ui.idleEnter());
    ui.stop_open = false;
    ui.future = @as(Io.Future(void), undefined);
    try std.testing.expect(!ui.idleEnter());
    ui.future = null;
    ui.settings_open = true;
    try std.testing.expect(!ui.idleEnter());
    ui.settings_open = false;
    ui.size.columns = 8;
    try std.testing.expect(!ui.idleEnter());
    ui.size.columns = 80;
    ui.size.rows = 6;
    try std.testing.expect(!ui.idleEnter());
    ui.size.rows = 24;
    _ = try ui.inbox.enqueue(std.testing.allocator, .steering, "pending");
    try std.testing.expect(!ui.idleEnter());
}
test "idle Enter precedes rapid nonempty submit and preserves following draft" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\r\rquestion\rnext draft", sink);
    try std.testing.expect(ui.deferred_submit != null);
    try std.testing.expectEqualStrings("question", ui.deferred_submit.?.editor.bytes.items);
    try std.testing.expectEqualStrings("next draft", ui.editor.bytes.items);
    try std.testing.expect(ui.future == null and !ui.busy and ui.prompt == null);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 2), ui.frame_idle_breaks);
    try ui.flushDeferredSubmit();
    try std.testing.expect(ui.deferred_submit != null and ui.future == null and !ui.busy and ui.prompt == null);
    try std.testing.expectEqualStrings("question", ui.deferred_submit.?.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    testAcknowledgeFullFrame(&ui);
    try ui.flushDeferredSubmit();
    try std.testing.expect(ui.deferred_submit == null and ui.future == null and !ui.busy and ui.prompt == null);
    try std.testing.expectEqualStrings("Not configured: use /login first", ui.notice);
    try std.testing.expectEqualStrings("next draft", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(NoticeLevel.failure, ui.records.items[0].notice_level);
}
test "idle Enter does not release an acknowledged draft erased in the same read batch" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("deleted-draft", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 1), screen.count("deleted-draft"));
    try ui.parser.feed("\x15\r", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), screen.count("deleted-draft"));
    try std.testing.expectEqual(@as(usize, 2), screen.count("?%>"));
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try ui.parser.feed("/", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .escape);
    try Ui.key(&ui, .clear);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), screen.count("deleted-draft"));
}
test "rendered unacknowledged body window applies admission pressure" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const index = try ui.add(.assistant, "");
    ui.draft = index;
    const bytes = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    try ui.records.items[index].append(std.testing.allocator, bytes);
    const body = ui.records.items[index].stream.?;
    try body.build();
    // Parsing is sliced: the first window is bounded and the remainder is still
    // queued, which is exactly the admission-pressure signal.
    try std.testing.expect(body.pendingBytes() != 0);
    try std.testing.expect(body.stats.max_window_bytes <= 4 * 1024 + 64 * 1024 + 2048);
    try std.testing.expectEqual(@as(usize, 128 * 1024), body.windowBytes());
    try std.testing.expect(ui.displayBackpressured());
    body.abort();
}
test "large history restore retains all records and identities" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var messages: [100]p.Message = undefined;
    var blocks: [100]p.Block = undefined;
    var labels: [100][32]u8 = undefined;
    for (&messages, 0..) |*message, i| {
        blocks[i] = .{ .text = try std.fmt.bufPrint(&labels[i], "restored-{d:0>3}", .{i}) };
        message.* = .{ .role = .user, .blocks = blocks[i .. i + 1] };
    }
    try replayMessages(&ui, std.testing.allocator, &messages);
    try std.testing.expectEqual(@as(usize, 100), ui.records.items.len);
    for (ui.records.items, 0..) |record, i| {
        try std.testing.expectEqual(Kind.user, record.kind);
        try std.testing.expectEqualStrings(blocks[i].text, record.body.items);
        try std.testing.expectEqual(i, ui.record_index.get(record.id).?);
    }
}
test "restore mixed long multi-block assistants retains all bytes" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const chunk = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'x');
    const blocks = [_]p.Block{ .{ .text = chunk }, .{ .text = chunk } };
    var messages: [24]p.Message = undefined;
    var short_blocks: [24]p.Block = undefined;
    var labels: [24][32]u8 = undefined;
    for (&messages, 0..) |*message, i| {
        if (i % 2 == 0) {
            message.* = .{ .role = .assistant, .blocks = &blocks };
        } else {
            short_blocks[i] = .{ .text = try std.fmt.bufPrint(&labels[i], "short-{d:0>3}", .{i}) };
            message.* = .{ .role = .user, .blocks = short_blocks[i .. i + 1] };
        }
    }
    try replayMessages(&ui, std.testing.allocator, &messages);
    var bytes: usize = 0;
    var assistants: usize = 0;
    for (ui.records.items) |record| {
        bytes += record.body.items.len;
        if (record.kind == .assistant) assistants += 1;
    }
    try std.testing.expect(bytes > 1024 * 1024);
    try std.testing.expectEqual(messages.len, ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 12), assistants);
    try std.testing.expectEqual(Kind.user, ui.records.items[ui.records.items.len - 1].kind);
    try std.testing.expectEqualStrings("short-023", ui.records.items[ui.records.items.len - 1].body.items);
}
test "normal admission never evicts unprinted records" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const first = try ui.add(.user, "oldest-pending");
    const first_id = ui.records.items[first].id;
    for (1..100) |_| _ = try ui.add(.user, "pending");
    _ = try ui.add(.user, "overflow");
    try std.testing.expectEqual(@as(usize, 101), ui.records.items.len);
    try std.testing.expect(!ui.displayBackpressured());
    try std.testing.expectEqual(first_id, ui.records.items[0].id);
    try std.testing.expectEqualStrings("oldest-pending", ui.records.items[0].body.items);
    try std.testing.expectEqualStrings("pending", ui.records.items[63].body.items);
    for (ui.records.items) |record| try std.testing.expect(!record.output);
}
test "real frame ignores a record removed before ack" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const first = try ui.add(.user, "old pending");
    try ui.draw();
    const id = ui.records.items[first].id;
    ui.removeRecord(first);
    const second = try ui.add(.user, "new pending");
    try std.testing.expect(ui.records.items[second].id != id);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(!ui.records.items[second].output);
}
test "frame descriptor keeps its checkpoint across stream append" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 80, .rows = 7 };
    const index = try ui.add(.assistant, "one\n\ntwo\n\nthree\n\nfour\n\nfive\n\nsix\n\nseven\n\n");
    ui.draft = index;
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 1), ui.frame_records.len);
    const checkpoint = ui.frame_records[0].stream_rows;
    try std.testing.expect(checkpoint != 0);
    const generation = ui.frame_records[0].generation;
    try ui.records.items[index].append(std.testing.allocator, "later\n");
    try std.testing.expectEqual(checkpoint, ui.frame_records[0].stream_rows);
    try std.testing.expectEqual(generation, ui.records.items[index].stream_generation);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(checkpoint, ui.records.items[index].stream_written);
    try std.testing.expect(!ui.records.items[index].output);
}
test "frame descriptors ignore removed and replaced records" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const index = try ui.add(.assistant, "first");
    const id = ui.records.items[index].id;
    var entries = [_]FrameRecord{.{ .record_id = id, .generation = ui.records.items[index].stream_generation, .output_candidate = true }};
    try ui.records.items[index].resetStream();
    ui.frame_records = &entries;
    ui.frame = "x";
    ui.frame_fresh = true;
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(!ui.records.items[index].output);
    ui.removeRecord(index);
    try std.testing.expect(ui.record_index.get(id) == null);
    entries[0] = .{ .record_id = id, .generation = 0, .output_candidate = true };
    ui.frame_records = &entries;
    ui.frame = "x";
    testAcknowledgeFullFrame(&ui);
}
test "resize ABA discards frame checkpoint and fresh draw can commit" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 80, .rows = 24 };
    const index = try ui.add(.user, "resize pending");
    try ui.draw();
    ui.resize(.{ .columns = 70, .rows = 24 });
    ui.resize(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(!ui.records.items[index].output);
    try std.testing.expectEqual(@as(usize, 0), ui.frame_records.len);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].output);
}
test "frame abort keeps unacknowledged record" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const index = try ui.add(.assistant, "first");
    var entries = [_]FrameRecord{.{ .record_id = ui.records.items[index].id, .generation = ui.records.items[index].stream_generation, .output_candidate = true }};
    ui.frame_records = &entries;
    ui.discardResizedFrame();
    try std.testing.expect(!ui.records.items[index].output);
    try std.testing.expect(ui.records.items[index].stream != null);
}
test "acknowledged and frame-owned records survive subsequent admissions" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const index = try ui.add(.user, "pending");
    const id = ui.records.items[index].id;
    ui.records.items[index].output = true;
    ui.records.items[index].pending_output = true;
    ui.records.items[index].pending_flow_change = true;
    for (0..70) |_| _ = try ui.add(.user, "later");
    try std.testing.expectEqual(id, ui.records.items[0].id);
    try std.testing.expect(ui.records.items[0].pending_output);
    try std.testing.expect(ui.records.items[0].pending_flow_change);
    try std.testing.expectEqual(@as(usize, 0), ui.record_index.get(id).?);
}
test "idle Enter waits for pending transcript output before releasing prompt rows" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    var record = Record{ .kind = .user };
    try record.append(std.testing.allocator, "pending-output");
    try ui.record_index.ensureUnusedCapacity(std.testing.allocator, 1);
    try ui.records.append(std.testing.allocator, record);
    try ui.registerRecord(ui.records.items.len - 1);
    try Ui.key(&ui, .enter);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
    try std.testing.expect(ui.records.items[0].pending_output);
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 1), ui.frame_idle_breaks);
    testAcknowledgeFullFrame(&ui);
}
test "idle Enter display barrier also precedes a rapid compact command" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r/compact\r", .{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expect(ui.deferred_submit != null);
    try std.testing.expectEqualStrings("/compact", ui.deferred_submit.?.editor.bytes.items);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 1), ui.frame_idle_breaks);
    try ui.flushDeferredSubmit();
    try std.testing.expect(ui.deferred_submit != null);
    testAcknowledgeFullFrame(&ui);
    try ui.flushDeferredSubmit();
    try std.testing.expect(ui.deferred_submit == null and ui.future == null);
    try std.testing.expectEqualStrings("Not configured: use /login first", ui.notice);
}
test "idle Enter acknowledged prompts survive a command popup without duplication" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    for (0..3) |_| try Ui.key(&ui, .enter);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const old_history = screen.history_len;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.menu_history.?.borrowed.len != 0);
    try Ui.key(&ui, .escape);
    try Ui.key(&ui, .clear);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(old_history, screen.history_len);
    try std.testing.expectEqual(@as(usize, 4), screen.count("?%>"));
    // Releasing this restored bottom-anchored tail keeps every prompt once.
    try Ui.key(&ui, .enter);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(old_history + 1, screen.history_len);
    try std.testing.expectEqual(@as(usize, 5), screen.count("?%>"));
    try ui.parser.feed("/", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .escape);
    try Ui.key(&ui, .clear);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 5), screen.count("?%>"));
}
test "idle Enter keeps a newly published diagnostic visible across redraws" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .enter);
    ui.notice = "new-safety-diagnostic";
    ui.observeAdvisories();
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(NoticeLevel.warning, ui.records.items[0].notice_level);
    for (0..3) |_| {
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expect(screen.visible("new-safety-diagnostic"));
    }
    try std.testing.expect(!ui.compact_composer);
}
test "idle notice survives acknowledgement of an already staged prompt frame" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try seedPriorBottom(&screen);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const history_before = screen.history_len;
    try Ui.key(&ui, .enter);
    try ui.draw(); // The old one-line idle frame has not been acknowledged.
    try std.testing.expectEqual(@as(u16, 1), ui.frame_idle_breaks);
    try std.testing.expectEqual(@as(usize, 1), ui.frame_height);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ui.frame[0..ui.frame_idle_prefix_end], "\n"));
    try ui.appendNotice(.warning, "staged-idle-diagnostic");
    try std.testing.expect(ui.idle_notice_barrier);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(history_before + 1, screen.history_len);
    try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    try std.testing.expect(!ui.compact_composer);
    for (0..2) |_| {
        try ui.draw();
        try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expect(!ui.compact_composer);
        try std.testing.expect(screen.visible("staged-idle-diagnostic"));
        try std.testing.expectEqual(@as(usize, 1), screen.count("staged-idle-diagnostic"));
        try std.testing.expectEqual(@as(usize, 2), screen.count("?%>"));
    }
}
test "idle Enter resize at every frame byte never replays or drops CRLF" {
    var frame_length: usize = 1;
    var offset: usize = 0;
    while (offset < frame_length) : (offset += 1) {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        try Ui.key(&ui, .enter);
        try Ui.key(&ui, .enter);
        try ui.draw();
        frame_length = ui.frame.len;
        const prefix_end = ui.frame_idle_prefix_end;
        const sent = std.mem.count(u8, ui.frame[0..@min(offset, prefix_end)], "\n");
        ui.frame_offset = offset;
        ui.resize(.{ .columns = 40, .rows = 24 });
        const remaining: u16 = @intCast(2 - sent);
        try std.testing.expectEqual(remaining, ui.idle_breaks);
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ui.resize_rescue, "\n"));
        const rescue = ui.resize_rescue;
        ui.resize(.{ .columns = 16, .rows = 24 });
        try std.testing.expectEqualStrings(rescue, ui.resize_rescue);
        try std.testing.expect(ui.frame.len == 0 and ui.frame_offset == 0 and !ui.frame_fresh);
        ui.finishFrame(); // Discarded old frames cannot consume pending requests.
        try std.testing.expectEqual(remaining, ui.idle_breaks);
        try std.testing.expect(ui.tail_snapshot == null);
        ui.resize_rescue = ""; // Simulate the controls-only cleanup being written.
        try ui.draw();
        try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
        testAcknowledgeFullFrame(&ui); // Establish a fresh-width composer first.
        try ui.draw();
        try std.testing.expectEqual(remaining, ui.frame_idle_breaks);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    }
}
test "idle Enter captured before resize waits until a supported composer is acknowledged" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .enter);
    ui.resize(.{ .columns = 1, .rows = 24 });
    for (0..2) |_| {
        try ui.draw();
        try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(u16, 1), ui.idle_breaks);
    }
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 1), ui.frame_idle_breaks);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
}
test "idle Enter waits quietly after partial frame shrinks below supported size" {
    for ([_]terminal_module.Size{ .{ .columns = 8, .rows = 24 }, .{ .columns = 80, .rows = 6 }, .{ .columns = 8, .rows = 6 } }) |small| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        try ui.draw();
        ui.dirty = false;
        testAcknowledgeFullFrame(&ui);
        try Ui.key(&ui, .enter);
        try Ui.key(&ui, .enter);
        try ui.draw();
        ui.dirty = false;
        ui.frame_offset = 1; // No accepted LF has reached the terminal yet.
        ui.resize(small);
        ui.resize_rescue = ""; // Simulate controls-only cleanup being written.
        try std.testing.expect(ui.drawReady());
        try ui.draw();
        ui.dirty = false;
        try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
        testAcknowledgeFullFrame(&ui);
        for (0..4) |_| {
            ui.clock_ms += 80;
            ui.animate();
            try std.testing.expect(!ui.drawReady());
            try std.testing.expectEqual(@as(u16, 2), ui.idle_breaks);
        }
        ui.resize(.{ .columns = 80, .rows = 24 });
        try std.testing.expect(ui.drawReady());
        try ui.draw();
        ui.dirty = false;
        try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
        testAcknowledgeFullFrame(&ui); // The new supported composer is now fully ACKed.
        try std.testing.expect(ui.drawReady());
        try ui.draw();
        ui.dirty = false;
        try std.testing.expectEqual(@as(u16, 2), ui.frame_idle_breaks);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
        try ui.draw();
        ui.dirty = false;
        testAcknowledgeFullFrame(&ui);
        try std.testing.expect(!ui.drawReady());
    }
}
test "idle Enter staging OOM keeps request draft and acknowledged ownership" {
    // Optional arena resize/remap can change allocation counts after an injected
    // failure. As in tailAllocationScenario, deny backing growth deterministically
    // while still exercising every required fresh allocation and leak check.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), idleEnterAllocationScenario, .{});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}
test "complete bridge source preserves actual runtime truncation provenance" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.job.kind = .command;
    const stdout = try a.alloc(u8, bridge_module.item_budget + 4096);
    defer a.free(stdout);
    @memset(stdout, 'x');
    const result = try std.fmt.allocPrint(a, "{{\"stdout\":\"{s}\",\"stderr\":\"UNAVAILABLE_BRIDGE_TAIL\",\"exit_code\":7}}", .{stdout});
    defer a.free(result);
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 1, .name = "bash", .result = .{ .text = result, .is_error = true, .truncated = true } } }, &cancel);
    var item = bridge.pop() orelse return error.MissingToolUiEvent;
    defer item.deinit();
    try std.testing.expect(!item.display_truncated);
    try std.testing.expect(item.event.tool_result.result.truncated);
    try std.testing.expectEqualStrings(result, item.event.tool_result.result.text);
    try ui.event(item);
    try std.testing.expectEqual(@as(usize, 3), ui.records.items.len);
    try std.testing.expect(ui.records.items[0].command_row);
    try std.testing.expect(std.mem.startsWith(u8, ui.records.items[1].body.items, stdout));
    try std.testing.expect(!ui.records.items[1].clipped); // Below the formatter's independent cap.
    try std.testing.expectEqual(Kind.notice, ui.records.items[2].kind);
    try std.testing.expect(std.mem.indexOf(u8, ui.records.items[2].body.items, "result was truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, ui.records.items[1].body.items, "UNAVAILABLE_BRIDGE_TAIL") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, "\"exit_code\":7}"));
    try ui.draw();
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "Local command result was truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, ui.records.items[1].body.items, "Command exited with status 7") != null);
}
test "local command captured truncation is not display clipping" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.localCommandOutput("{\"stdout\":\"hello\",\"stderr\":\"\",\"exit_code\":0,\"truncated\":true}", false);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    const record = &ui.records.items[0];
    try std.testing.expect(!record.clipped);
    try std.testing.expect(std.mem.indexOf(u8, record.body.items, "[output truncated]") != null);
    try record.layout(std.testing.allocator, 80);
    for (record.lines) |line| try std.testing.expect(std.mem.indexOf(u8, line, "[display clipped") == null);
}
test "local command outer truncation remains visible with incomplete JSON" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.localCommandOutput("{\"stdout\":\"partial", true);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqualStrings("{\"stdout\":\"partial", ui.records.items[0].body.items);
    try std.testing.expectEqual(Kind.notice, ui.records.items[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, ui.records.items[1].body.items, "result was truncated") != null);
    try std.testing.expect(ui.future == null);
}
test "local command live streams are visible literal and normal tools stay captions" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.job.kind = .command;
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .assistant_committed = &.{
        .{ .text = "Program-generated bash call for the user's explicit !command; not LLM reasoning or a model response." },
        .{ .tool_call = .{ .id = "local_command_1", .name = "bash", .arguments = "{\"command\":\"exit 7\"}" } },
    } }, &cancel);
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 1, .name = "bash", .result = .{ .text = "{\"stdout\":\"**literal**\\n\\u001b[2J\",\"stderr\":\"visible-error\",\"exit_code\":7}", .is_error = true } } }, &cancel);
    while (bridge.pop()) |value| {
        var item = value;
        defer item.deinit();
        try ui.event(item);
    }
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expect(ui.records.items[0].command_row);
    try std.testing.expect(!ui.records.items[1].command_row and ui.records.items[1].kind == .tool);
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    for ([_][]const u8{ "**literal**", "visible-error", "Command exited with status 7" }) |label| try std.testing.expectEqual(@as(usize, 1), screen.count(label));
    for ([_][]const u8{ "stdout:", "stderr:", "exit:", "output encoding:" }) |label| try std.testing.expectEqual(@as(usize, 0), screen.count(label));
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "Program-generated") == null);
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "\x1b[2J") == null);
    try ui.records.items[1].layout(std.testing.allocator, 5);
    for (ui.records.items[1].lines) |line| {
        var offset: usize = 0;
        var columns: usize = 0;
        while (offset < line.len) {
            const cluster = text.nextStyledCluster(line, offset, columns);
            columns += cluster.width;
            offset = cluster.end;
        }
        try std.testing.expect(columns <= 5);
    }
    ui.job.kind = .prompt;
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 2, .name = "bash", .result = .{ .text = "normal-hidden-output" } } }, &cancel);
    while (bridge.pop()) |value| {
        var item = value;
        defer item.deinit();
        try ui.event(item);
    }
    try std.testing.expectEqual(@as(usize, 3), ui.records.items.len);
    try std.testing.expect(ui.records.items[2].command_row);
    try std.testing.expect(std.mem.indexOf(u8, ui.records.items[2].body.items, "normal-hidden-output") == null);
}
test "local command restore is adjacent display only with paired result" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const messages = [_]p.Message{
        .{ .role = .user, .blocks = &.{.{ .text = "  !exit 7" }} },
        .{ .role = .assistant, .blocks = &.{
            .{ .text = "Program-generated bash call for the user's explicit !command; not LLM reasoning or a model response." },
            .{ .tool_call = .{ .id = "local_command_1", .name = "bash", .arguments = "{\"command\":\"must-not-execute\"}" } },
        } },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "local_command_1", .text = "{\"stdout\":\"restored-stream\",\"stderr\":\"restored-error\",\"exit_code\":7}", .is_error = true } }} },
    };
    try std.testing.expect(r.isLocalCommand(messages[1].blocks[1].tool_call.id));
    try replayMessages(&ui, std.testing.allocator, &messages);
    try std.testing.expect(bridge.pop() == null);
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqual(@as(usize, 3), ui.records.items.len);
    try std.testing.expect(ui.records.items[1].command_row);
    try std.testing.expect(!ui.records.items[2].command_row);
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    for ([_][]const u8{ "restored-stream", "restored-error", "Command exited with status 7" }) |label| try std.testing.expectEqual(@as(usize, 1), screen.count(label));
    for ([_][]const u8{ "stdout:", "stderr:", "exit:", "output encoding:" }) |label| try std.testing.expectEqual(@as(usize, 0), screen.count(label));
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "Program-generated") == null);
}
test "command elapsed time uses source timestamps freezes results and resets per call" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const host = bridge.host();
    const drain = struct {
        fn apply(target: *Ui) !void {
            while (target.bridge.pop()) |value| {
                var item = value;
                defer item.deinit();
                try target.event(item);
            }
        }
    }.apply;
    ui.clock_ms = 5000; // UI may consume both events long after execution.
    try host.emit_fn(host.context, .{ .tool_started = .{ .id = 1, .name = "bash", .started_ms = 1000 } }, &cancel);
    try drain(&ui);
    const running = try ui.pendingCommand(std.testing.allocator, 79);
    defer std.testing.allocator.free(running);
    try std.testing.expect(std.mem.endsWith(u8, running, "4.00s" ++ theme.reset));
    ui.clock_ms = 5500;
    const later = try ui.pendingCommand(std.testing.allocator, 79);
    defer std.testing.allocator.free(later);
    try std.testing.expect(std.mem.endsWith(u8, later, "4.50s" ++ theme.reset));
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 1, .name = "bash", .result = .{ .text = "done", .duration_ms = 420 } } }, &cancel);
    try drain(&ui);
    try std.testing.expectEqual(@as(?u64, 420), ui.records.items[0].duration_ms);
    try ui.records.items[0].layout(std.testing.allocator, 79);
    try std.testing.expect(std.mem.endsWith(u8, ui.records.items[0].lines[0], "420ms" ++ theme.reset));
    ui.clock_ms = 8000;
    try ui.records.items[0].layout(std.testing.allocator, 60); // Resize cannot restart a completed timer.
    try std.testing.expect(std.mem.endsWith(u8, ui.records.items[0].lines[0], "420ms" ++ theme.reset));
    // Start/result drained in the same UI tick retain the measured duration.
    try host.emit_fn(host.context, .{ .tool_started = .{ .id = 2, .name = "bash", .started_ms = 6100 } }, &cancel);
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 2, .name = "bash", .result = .{ .text = "failed", .is_error = true, .duration_ms = 230 } } }, &cancel);
    try drain(&ui);
    try std.testing.expectEqual(@as(?u64, 230), ui.records.items[1].duration_ms);
    try std.testing.expectEqual(presentation.Outcome.failed, ui.records.items[1].command_spans.items[0].outcome);
    // A denied/preparation-failed call did not execute: do not invent 0ms.
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 3, .name = "bash", .result = .{ .text = "not executed", .is_error = true } } }, &cancel);
    try drain(&ui);
    try std.testing.expect(ui.records.items[2].duration_ms == null);
}
test "regular transcript writes committed rows above a natural composer tail without role tags" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.user, "unique committed user");
    try ui.appendDraft(.assistant, "uncanonical draft");
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "unique committed user") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Streaming") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "History preview") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "[user]") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "[assistant") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.user_background) != null);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    // One released user row above the gap+draft body and the hinted composer.
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    try std.testing.expect(std.mem.find(u8, &screen.grid[screen.rows - 1 - ui.frame_height], "unique committed user") != null);
    try std.testing.expect(!ui.records.items[0].output);
    try std.testing.expectEqual(@as(usize, 5), ui.frame_height); // One committed user row, no full-screen padding.
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[0].output);
    try std.testing.expect(!ui.records.items[1].output);
    try ui.replaceCommitted(&.{.{ .text = "unique canonical reply" }}, false, true);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "unique committed user") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "uncanonical draft") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "unique canonical reply") != null);
    try std.testing.expectEqual(@as(usize, 3), ui.frame_height); // Leading gap + canonical body, no title.
    try screen.replay(ui.frame);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    try std.testing.expectEqual(@as(usize, 1), screen.count("unique canonical reply"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "unique canonical reply") == null);
    try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r\x1b[2A"));
    for ([_][]const u8{ "1049", "1047", "\x1b[H", "\x1b[2J", ";1H" }) |forbidden|
        try std.testing.expect(std.mem.find(u8, ui.frame, forbidden) == null);
}
test "static assistant EOF drains once without phantom transcript rows" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const index = try ui.add(.assistant, "static-row-one\nstatic-row-two");
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].output);
    try std.testing.expect(ui.records.items[index].stream.?.isDrained());
    const before = screen.grid;
    const history_before = screen.history_len;
    const above_before = ui.menu_history.?.above.len;
    try ui.draw();
    try std.testing.expectEqual(above_before, ui.frame_menu_history.?.above.len);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(history_before, screen.history_len);
    for (before[0 .. ui.size.rows - 2], screen.grid[0 .. ui.size.rows - 2]) |old, actual|
        try std.testing.expectEqualStrings(&old, &actual);
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/", sink);
    try ui.draw();
    // Opening a menu may borrow owned rows, but cannot append new transcript.
    const menu_history = ui.frame_menu_history.?;
    try std.testing.expectEqual(above_before, menu_history.above.len + menu_history.borrowed.len);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(history_before, screen.history_len);
}
test "growing a compact live tail keeps replaceable drafts out of scrollback" {
    for ([_]bool{ false, true }) |same_final| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        var old: std.ArrayList(u8) = .empty;
        defer old.deinit(std.testing.allocator);
        for (0..20) |_| try old.appendSlice(std.testing.allocator, "older-row\n");
        try old.appendSlice(std.testing.allocator, "last-older-row");
        _ = try ui.add(.assistant, old.items);
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(usize, 3), ui.tail_height);
        try std.testing.expectEqual(@as(usize, 23), screen.row);

        try ui.appendDraft(.assistant, "growth-draft-marker\nsecond-draft-line");
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(usize, 6), ui.tail_height); // Gap + two draft rows + hinted footer; no preview-title row.
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        const draft_row = screen.row;
        for (screen.history[0..screen.history_len]) |line| try std.testing.expect(std.mem.find(u8, &line, "growth-draft-marker") == null);

        try ui.replaceCommitted(&.{.{ .text = if (same_final) "growth-draft-marker" else "different-final-marker" }}, false, true);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(usize, @intFromBool(same_final)), screen.count("growth-draft-marker"));
        try std.testing.expectEqual(@as(usize, @intFromBool(!same_final)), screen.count("different-final-marker"));
        try std.testing.expectEqual(@as(usize, 0), screen.count("second-draft-line"));
        // The released rows plus reused tail preserve the physical bottom.
        try std.testing.expectEqual(draft_row, screen.row);
        try std.testing.expectEqual(@as(usize, 4), ui.tail_height);
    }
}
test "user thinking streaming prefixes and revised replies keep explicit gaps" {
    for ([_]usize{ 80, 20 }) |columns| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.size.columns = columns;
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        _ = try ui.add(.user, "user-row-one\nuser-row-end");
        try ui.appendDraft(.reasoning, "old-think\nthink-first\nthink-second\nthink-last");
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "user-row-end", "think-last");
        try std.testing.expect(screen.visible("think-last"));
        try std.testing.expectEqual(@as(usize, 1), screen.count("think-last"));
        for ([_][]const u8{ "old-think", "think-first", "think-second" }) |marker| try std.testing.expectEqual(@as(usize, 0), screen.count(marker));
        // Two released user rows and the live reasoning stay above the footer.
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
        try ui.appendDraft(.reasoning, "\nthink-new\nthink-new-last");
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "user-row-end", "think-new-last");
        try std.testing.expect(screen.visible("think-new-last"));
        try std.testing.expectEqual(@as(usize, 1), screen.count("think-new-last"));
        for ([_][]const u8{ "old-think", "think-first", "think-second", "think-last" }) |marker| try std.testing.expectEqual(@as(usize, 0), screen.count(marker));
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
        try ui.appendDraft(.assistant, "live-start\nlive-end");
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "user-row-end", "live-start");
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        try std.testing.expectEqual(@as(usize, 0), screen.count("think-"));
        try std.testing.expect(std.mem.indexOf(u8, ui.frame, "Streaming") == null);
        try std.testing.expect(std.mem.indexOf(u8, ui.frame, "History preview") == null);
        testAcknowledgeFullFrame(&ui);
        // Growing native history preserves the original start and its gap,
        // instead of clipping the stream into a moving last-screen window.
        for (0..60) |i| {
            const delta = try std.fmt.allocPrint(std.testing.allocator, "\nlive-line-{d}", .{i});
            defer std.testing.allocator.free(delta);
            try ui.appendDraft(.assistant, delta);
        }
        const prior_tail = ui.tail_height;
        try ui.draw();
        // draw stages a new tail; tail_height remains the prior complete ACK.
        try std.testing.expectEqual(prior_tail, ui.tail_height);
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "user-row-end", "live-start");
        try std.testing.expect(screen.count("live-line-") > 0);
        try std.testing.expectEqual(@as(usize, 1), screen.count("user-row-end"));
        // The draft grew past the window, so its tail ends on the physical bottom
        // without necessarily owning every physical row.
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        // The staged footprint is the remaining draft rows after the pending
        // released prefix, plus any fresh leading gap and the fixture footer,
        // clamped to the physical window. A short bottom-anchored tail is valid.
        const draft_record = &ui.records.items[ui.draft.?];
        const released = draft_record.pending_stream_rows;
        try std.testing.expect(released != 0);
        const remaining = draft_record.lines.len -| released;
        const leading_gap: usize = @intFromBool(released == 0);
        const fixture_footer_rows: usize = 3; // notice, separator, composer
        const staged = @min(ui.size.rows, remaining + leading_gap + fixture_footer_rows);
        try std.testing.expectEqual(staged, ui.frame_height);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(staged, ui.tail_height);
        // First row owned by the ACKed tail: the revision frame starts here.
        try ui.replaceCommitted(&.{.{ .text = "formal-final" }}, false, true);
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "Response revised", "formal-final");
        try std.testing.expectEqual(@as(usize, 1), screen.count("formal-final"));
        try std.testing.expect(screen.count("live-line-") > 0);
        try std.testing.expectEqual(@as(usize, 1), screen.count("user-row-end"));
        // The revision and its footer remain anchored at the physical bottom.
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
    }
}
test "composer history arrows require exact origin while slash arrows only select commands" {
    const a = std.testing.allocator;
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    for ([_][]const u8{ "first\n中文", "second" }) |message|
        ui.input_history.commit(a, try ui.input_history.prepare(a, message));
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[B", sink);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try ui.parser.feed("\x1b[A", sink);
    try std.testing.expectEqualStrings("second", ui.editor.bytes.items);
    try ui.parser.feed("\x1b[A\x1b[A", sink);
    try std.testing.expectEqualStrings("first\n中文", ui.editor.bytes.items);
    try ui.parser.feed("\x1b[B\x1b[B", sink);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try ui.parser.feed("manual\x1b[A\x1b[B", sink);
    try std.testing.expectEqualStrings("manual", ui.editor.bytes.items);
    try ui.parser.feed("\x15\x1b[A\x1b[F-edited\x1b[A\x1b[B", sink);
    try std.testing.expectEqualStrings("second-edited", ui.editor.bytes.items);
    try std.testing.expect(ui.input_history.index == null);
    try ui.parser.feed("\x15/\x1b[B", sink);
    try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
    try std.testing.expectEqual(command_menu_module.Command.auth, ui.command_menu.choice(ui.command_matches).?);
    try std.testing.expect(!ui.busy and ui.future == null); // Browsing is never submission.
    ui.wipeEditor();
    ui.beginSecret(null);
    try ui.parser.feed("fake-secret-never-history", sink);
    ui.endSecret();
    try std.testing.expectEqual(@as(usize, 2), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("second", ui.input_history.target(false).?.text);
}
test "composer arrows move visual rows and only exact origin browses history with draft restoration" {
    const a = std.testing.allocator;
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 30, .rows = 12 };
    for ([_][]const u8{ "older", "newer" }) |message|
        ui.input_history.commit(a, try ui.input_history.prepare(a, message));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const prepared = try ui.prepareComposer(arena.allocator(), ui.connection.current(), 29);
    const width = 29 - text.width(prepared.decoration.plain);
    const draft = try a.alloc(u8, width * 3 + 3);
    defer a.free(draft);
    @memset(draft, 'x');
    _ = try ui.editor.insert(draft);
    ui.editor_pasted = true;
    ui.editor.cursor = width * 2 + 2;
    try Ui.key(&ui, .up);
    try std.testing.expectEqual(width + 2, ui.editor.cursor);
    try Ui.key(&ui, .up);
    try std.testing.expectEqual(@as(usize, 2), ui.editor.cursor);
    try Ui.key(&ui, .up); // Top row, nonzero column: never browse history.
    try std.testing.expectEqual(@as(usize, 2), ui.editor.cursor);
    try std.testing.expect(ui.input_history.index == null);
    try Ui.key(&ui, .down);
    try std.testing.expectEqual(width + 2, ui.editor.cursor);
    try std.testing.expectEqualStrings(draft, ui.editor.bytes.items);
    try Ui.key(&ui, .home);
    try Ui.key(&ui, .up);
    try std.testing.expectEqualStrings("newer", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.cursor);
    try Ui.key(&ui, .up);
    try std.testing.expectEqualStrings("older", ui.editor.bytes.items);
    try Ui.key(&ui, .down);
    try std.testing.expectEqualStrings("newer", ui.editor.bytes.items);
    try Ui.key(&ui, .down);
    try std.testing.expectEqualStrings(draft, ui.editor.bytes.items);
    try std.testing.expect(ui.editor_pasted and ui.history_draft == null and ui.input_history.index == null);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.cursor);
    try std.testing.expect(!ui.busy and ui.future == null);
}
test "composer history replacement allocation failure preserves original draft ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, composerHistoryAllocationScenario, .{});
}
test "editing recalled history commits draft ownership only after insertion succeeds" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, composerHistoryEditAllocationScenario, .{});

    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const full = try std.testing.allocator.alloc(u8, 65536);
    defer std.testing.allocator.free(full);
    @memset(full, 'h');
    ui.input_history.commit(std.testing.allocator, try ui.input_history.prepare(std.testing.allocator, full));
    _ = try ui.editor.insert("draft");
    ui.editor.cursor = 0;
    ui.editor_pasted = true;
    try ui.navigateInput(false);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const prior_allocator = ui.editor.allocator;
    ui.editor.allocator = failing.allocator();
    const insertion = try std.testing.allocator.alloc(u8, 65537);
    defer std.testing.allocator.free(insertion);
    @memset(insertion, 'x');
    const attempted = Ui.key(&ui, .{ .text = .{ .value = insertion, .pasted = false } });
    ui.editor.allocator = prior_allocator;
    try std.testing.expectError(error.OutOfMemory, attempted);
    try std.testing.expectEqual(@as(usize, 65536), ui.editor.bytes.items.len);
    try std.testing.expect(ui.input_history.index != null and ui.history_draft != null);
    try ui.navigateInput(true);
    try std.testing.expectEqualStrings("draft", ui.editor.bytes.items);
    try std.testing.expect(ui.editor_pasted);
}
test "Escape protects draft then cancels active task only from empty input" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("draft-next\x1b[200~\x1b[A\x1b[201~\x1b[", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(!cancel.isRequested());
    try ui.parser.feed("A", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(!cancel.isRequested());
    try ui.parser.feed("\x1b", sink);
    try std.testing.expect(!cancel.isRequested());
    try ui.parser.expireEscape(sink);
    try std.testing.expect(!cancel.isRequested() and !ui.ctrl_d_exit and !ui.exitAuthorized());
    try std.testing.expectEqualStrings("draft-next", ui.editor.bytes.items);
    ui.wipeEditor();
    try ui.parser.feed("\x1b", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(cancel.isRequested());
    try std.testing.expect(std.mem.startsWith(u8, ui.notice, "Cancellation requested"));
}
test "first entry anchor protects history and entry rows through idle exit" {
    for ([_]usize{ 0, 10, 23 }) |entry_row| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        screen.history_len = 1;
        screen.history[0] = @splat('P');
        for (0..screen.rows) |row| screen.grid[row][0] = @intCast('A' + row);
        screen.row = entry_row;
        ui.entry_origin = .{ .size = ui.size, .row = entry_row };
        ui.ctrl_d_exit = true;
        try ui.draw();
        var bytes: [2048]u8 = undefined;
        var writer = Io.Writer.fixed(&bytes);
        try std.testing.expect(!try ui.idleExitBytes(&writer)); // no ACK
        try screen.replay(ui.frame);
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expect(ui.entry_origin == null);
        try std.testing.expect(try ui.idleExitBytes(&writer));
        try screen.replay(writer.buffered());
        try std.testing.expectEqual(@as(u8, 'P'), screen.history[0][0]);
        try std.testing.expect(screen.history_len <= entry_row + 2);
        for (0..entry_row + 1) |row| {
            const logical = row + 1;
            const actual = if (logical < screen.history_len) screen.history[logical][0] else screen.grid[logical - screen.history_len][0];
            try std.testing.expectEqual(@as(u8, @intCast('A' + row)), actual);
        }
    }
}
test "natural entry owns only written rows and tracks a conservative endpoint" {
    for ([_]usize{ 0, 10, 23 }) |entry_row| {
        for ([_]bool{ false, true }) |known| {
            var cancel: p.Cancellation = .{};
            var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
            defer bridge.deinit();
            var ui = fixtureUi(&bridge, &cancel);
            defer ui.deinit();
            ui.natural_flow = true;
            var terminal: terminal_module.Terminal = .{ .fd = -1, .owned = false, .original = undefined, .original_flags = 0, .active = false };
            ui.terminal = &terminal;
            var screen: @import("../tests/regular_screen.zig").Screen = .{};
            screen.row = entry_row;
            screen.grid[entry_row][0] = 'P';
            if (known) ui.entry_origin = .{ .size = ui.size, .row = entry_row };
            try ui.draw();
            try std.testing.expect(ui.frame_relative and !ui.tail_relative);
            try std.testing.expectEqual(@as(usize, 0), ui.frame_menu_history.?.above.len);
            try screen.replay(ui.frame);
            try std.testing.expectEqual(@min(screen.rows - 1, entry_row + ui.frame_height), screen.row);
            testAcknowledgeFullFrame(&ui);
            try std.testing.expect(ui.tail_relative);
            try std.testing.expectEqual(@min(screen.rows - 1, (if (known) entry_row else 0) + ui.tail_height), ui.tail_end_floor);
            try std.testing.expect(!ui.tail_bottom);
            const prior = screen.row;
            _ = try ui.editor.insert("hello");
            try ui.draw();
            try screen.replay(ui.frame);
            try std.testing.expect(screen.row >= prior);
            testAcknowledgeFullFrame(&ui);
            ui.resize(.{ .columns = ui.size.columns - 1, .rows = ui.size.rows });
            try std.testing.expect(!ui.tail_relative and !ui.frame_relative and ui.tail_end_floor == 0);
        }
    }
}
test "natural partial write promotes staged proof only on complete frame ACK" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest; // Requires Linux F_SETPIPE_SZ.
    const Pipe = struct {
        extern "c" fn pipe2(*[2]c_int, c_int) c_int;
    };
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), Pipe.pipe2(&fds, 0x800 | 0x80000));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    // Linux F_SETPIPE_SZ: deterministic capacity below the enlarged frame.
    try std.testing.expectEqual(@as(c_int, 4096), std.c.fcntl(fds[1], 1031, @as(c_int, 4096)));

    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var terminal: terminal_module.Terminal = .{ .fd = fds[1], .owned = false, .original = undefined, .original_flags = 0, .active = false };
    ui.terminal = &terminal;
    ui.natural_flow = true;
    ui.entry_origin = .{ .size = ui.size, .row = 0 };
    try ui.draw();
    try std.testing.expect(ui.frame_relative and ui.frame_tail_snapshot != null);
    const floor = ui.frame_end_floor;
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    const first_row = screen.row;
    const raw = ui.frame;
    const expanded = try ui.frame_arena.?.allocator().alloc(u8, 16384 + raw.len);
    for (0..4096) |i| @memcpy(expanded[i * 4 ..][0..4], "\x1b[0m");
    @memcpy(expanded[16384..], raw);
    ui.frame = expanded;
    ui.tail_bottom = true;
    ui.tail_relative = true;
    ui.tail_end_floor = 9;
    try ui.writeFrame();
    try std.testing.expect(ui.frame_offset > 0 and ui.frame_offset < ui.frame.len);
    try std.testing.expect(!ui.tail_bottom and !ui.tail_relative and ui.tail_end_floor == 0);
    try std.testing.expect(ui.frame_relative and ui.frame_end_floor == floor and ui.frame_tail_snapshot != null);
    var drain: [8192]u8 = undefined;
    for (0..32) |_| {
        if (ui.frame.len == 0) break;
        const n = std.c.read(fds[0], &drain, drain.len);
        try std.testing.expect(n > 0);
        try ui.writeFrame();
    }
    try std.testing.expectEqual(@as(usize, 0), ui.frame.len);
    try std.testing.expect(ui.tail_relative and ui.tail_end_floor == floor and ui.tail_snapshot != null);
    try std.testing.expect(!ui.tail_bottom);
    _ = try ui.editor.insert("hello");
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ui.frame, "\n"));
    try screen.replay(ui.frame);
    try std.testing.expect(screen.row >= first_row);
}
test "natural idle prompts menus and long output retain native flow" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.natural_flow = true;
    var terminal: terminal_module.Terminal = .{ .fd = -1, .owned = false, .original = undefined, .original_flags = 0, .active = false };
    ui.terminal = &terminal;
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    screen.row = 1;
    ui.entry_origin = .{ .size = ui.size, .row = screen.row };
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    var row = screen.row;
    for (0..2) |cycle| {
        try Ui.key(&ui, .enter);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expect(screen.row >= row);
        try std.testing.expectEqual(cycle + 2, screen.count("?%>"));
        const before_menu = screen.history_len + screen.row;
        try ui.parser.feed("/model", sink);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expect(ui.commandMenuVisible());
        try Ui.key(&ui, .escape);
        try Ui.key(&ui, .clear);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(cycle + 2, screen.count("?%>"));
        try std.testing.expectEqual(before_menu, screen.history_len + screen.row);
        row = screen.row;
        for (0..2) |_| {
            try ui.draw();
            try screen.replay(ui.frame);
            testAcknowledgeFullFrame(&ui);
            try std.testing.expectEqual(row, screen.row);
            try std.testing.expectEqual(cycle + 2, screen.count("?%>"));
        }
    }
    var body: Io.Writer.Allocating = .init(a);
    defer body.deinit();
    for (0..80) |i| try body.writer.print("natural-line-{d:0>3}\n", .{i});
    const answer = try ui.add(.assistant, body.written());
    for (0..128) |_| {
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        if (ui.records.items[answer].output) break;
    }
    try std.testing.expect(ui.records.items[answer].output);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    try std.testing.expect(!ui.tail_bottom and ui.tail_relative);
    for (0..2) |_| {
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(screen.rows - 1, screen.row);
    }
    const bottom_height = ui.tail_height;
    const bottom_history = screen.history_len;
    try ui.parser.feed("/", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .clear);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.tail_height >= bottom_height);
    try std.testing.expect(screen.history_len >= bottom_history);
    for (0..80) |i| {
        var marker: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&marker, "natural-line-{d:0>3}", .{i});
        try std.testing.expectEqual(@as(usize, 1), screen.count(name));
    }
}
test "natural command menu reclaims only acknowledged temporary rows" {
    for ([_]usize{ 0, 10 }) |entry| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.natural_flow = true;
        var terminal: terminal_module.Terminal = .{ .fd = -1, .owned = false, .original = undefined, .original_flags = 0, .active = false };
        ui.terminal = &terminal;
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        screen.history_len = 1;
        screen.history[0] = @splat(' ');
        @memcpy(screen.history[0][0..12], "protected-01");
        screen.row = entry;
        ui.entry_origin = .{ .size = ui.size, .row = entry };
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        const endpoint = screen.history_len + screen.row;
        const height = ui.tail_height;
        for (0..2) |cycle| {
            try ui.parser.feed("/", sink);
            try ui.draw();
            try screen.replay(ui.frame);
            testAcknowledgeFullFrame(&ui);
            try std.testing.expect(ui.tail_menu_extra > 0);
            try ui.parser.feed("model", sink);
            try ui.draw();
            try screen.replay(ui.frame);
            testAcknowledgeFullFrame(&ui);
            for (0..5) |_| try Ui.key(&ui, .backspace);
            try ui.draw();
            try screen.replay(ui.frame);
            testAcknowledgeFullFrame(&ui);
            if (cycle == 0) try Ui.key(&ui, .escape);
            try Ui.key(&ui, .clear);
            try ui.draw();
            try screen.replay(ui.frame);
            testAcknowledgeFullFrame(&ui);
            try std.testing.expectEqual(endpoint, screen.history_len + screen.row);
            try std.testing.expectEqual(height, ui.tail_height);
            try std.testing.expectEqual(@as(usize, 0), ui.tail_menu_extra);
            try std.testing.expectEqual(@as(usize, 1), screen.count("protected-01"));
        }
        // Staged expansion is not an ACK, and resize ABA revokes both copies.
        try ui.parser.feed("/", sink);
        try ui.draw();
        try std.testing.expect(ui.frame_menu_extra > 0 and ui.tail_menu_extra == 0);
        ui.frame_offset = 1;
        const original = ui.size;
        ui.resize(.{ .columns = original.columns - 1, .rows = original.rows });
        ui.resize(original);
        try std.testing.expect(!ui.tail_relative and !ui.frame_relative);
        try std.testing.expectEqual(@as(usize, 0), ui.tail_menu_extra);
        try std.testing.expectEqual(@as(usize, 0), ui.frame_menu_extra);
    }
}
test "repeated bare command menus preserve three idle releases" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.natural_flow = true;
    var terminal: terminal_module.Terminal = .{ .fd = -1, .owned = false, .original = undefined, .original_flags = 0, .active = false };
    ui.terminal = &terminal;
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    screen.row = 10;
    ui.entry_origin = .{ .size = ui.size, .row = 10 };
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    for (0..3) |_| {
        try Ui.key(&ui, .enter);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
    }
    try std.testing.expect(ui.compact_composer);
    try std.testing.expect(ui.menu_history != null and ui.menu_history.?.above.len >= 3);
    const endpoint = screen.history_len + screen.row;
    const prompt_count = screen.count("?%>");
    try std.testing.expectEqual(@as(usize, 4), prompt_count);
    for (0..3) |_| {
        try ui.parser.feed("/", sink);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try Ui.key(&ui, .escape);
        try Ui.key(&ui, .clear);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(endpoint, screen.history_len + screen.row);
        try std.testing.expectEqual(prompt_count, screen.count("?%>"));
        try std.testing.expectEqual(@as(usize, 0), ui.tail_menu_extra);
    }
}
test "first entry origin is not revived by resize ABA or frame acknowledgement" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const original = ui.size;
    ui.natural_flow = true;
    var terminal: terminal_module.Terminal = .{ .fd = -1, .owned = false, .original = undefined, .original_flags = 0, .active = false };
    ui.terminal = &terminal;
    ui.entry_origin = .{ .size = original, .row = 10 };
    try ui.draw();
    try std.testing.expect(ui.entry_origin != null and ui.frame_relative);
    ui.frame_offset = 1;
    ui.resize(.{ .columns = original.columns - 1, .rows = original.rows });
    try std.testing.expect(ui.entry_origin == null and ui.resize_rescue.len != 0);
    try std.testing.expect(!ui.tail_relative and !ui.frame_relative and ui.frame_end_floor == 0);
    var bytes: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&bytes);
    try std.testing.expect(!try ui.idleExitBytes(&writer));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    ui.resize(original);
    try std.testing.expect(ui.entry_origin == null and !ui.tail_relative and !ui.frame_relative);
    try std.testing.expect(!try ui.idleExitBytes(&writer));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}
test "early ctrl d never writes an unseen initial frame" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.entry_origin = .{ .size = ui.size, .row = 4 };
    try ui.draw();
    ui.ctrl_d_exit = true;
    try std.testing.expect(ui.initialExitWithoutFrame());
    try ui.drainExit();
    try std.testing.expect(ui.frame.len != 0 and ui.frame_offset == 0);
    ui.frame_offset = 1;
    try std.testing.expect(!ui.initialExitWithoutFrame());
    ui.frame_offset = 0;
    _ = try ui.add(.assistant, "pending output");
    try std.testing.expect(!ui.initialExitWithoutFrame());
}
test "exit blank cleanup reclaims acknowledged edges and preserves startup and shell history" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.current_fn = FixtureConnection.configuredCurrent;
    _ = try ui.add(.notice, "thin fixture-version\n/fixture\nfixture UTC");
    ui.notice = "fixture-footer";
    ui.observeAdvisories();
    ui.ctrl_d_exit = true;
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay("shell-kept\r\n");
    try ui.draw();
    try std.testing.expect(ui.frame_exit_separator and !ui.tail_exit_separator);
    var buf: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);
    try std.testing.expect(!try ui.idleExitBytes(&writer));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    // The marker is now an acknowledged transcript row, not a footer row.
    try std.testing.expectEqual(@as(usize, 2), ui.tail_height);
    try std.testing.expect(ui.tail_exit_separator);
    try std.testing.expectEqualStrings("\x1b[0m\x1b[0m\x1b[K", ui.tail_snapshot.?.rows[0]);
    try std.testing.expect(try ui.idleExitBytes(&writer));
    const history_before = try std.testing.allocator.dupe(@TypeOf(screen.history[0]), screen.history[0..screen.history_len]);
    defer std.testing.allocator.free(history_before);
    try screen.replay(writer.buffered());
    try std.testing.expectEqualSlices(@TypeOf(screen.history[0]), history_before, screen.history[0..screen.history_len]);
    var last_content: ?usize = null;
    for (screen.grid[0..screen.rows], 0..) |line, index| {
        if (std.mem.indexOf(u8, &line, "fixture-footer") != null) last_content = index;
    }
    try std.testing.expect(last_content != null);
    try std.testing.expect(last_content.? < 8);
    try screen.replay("\r\nshell-next");
    try std.testing.expect(screen.row < 8);
    try std.testing.expectEqualSlices(@TypeOf(screen.history[0]), history_before, screen.history[0..screen.history_len]);
    try std.testing.expectEqual(@as(usize, 0), screen.count("Session ID:"));
    try std.testing.expectEqual(last_content.? + 1, screen.row);
    for ([_][]const u8{ "shell-kept", "thin fixture-version", "/fixture", "fixture UTC", "fixture-footer", "shell-next" }) |marker|
        try std.testing.expectEqual(@as(usize, 1), screen.count(marker));

    const Denied = struct {
        fn check(state: *Ui) !void {
            var bytes: [2048]u8 = undefined;
            var out = Io.Writer.fixed(&bytes);
            try std.testing.expect(!try state.idleExitBytes(&out));
            try std.testing.expectEqual(@as(usize, 0), out.buffered().len);
        }
    };
    const snapshot_rows = ui.tail_snapshot.?.rows;
    const unexpected_rows = [_][]const u8{ "\x1b[31mnot blank\x1b[0m\x1b[K", snapshot_rows[1] };
    ui.tail_snapshot.?.rows = &unexpected_rows;
    try Denied.check(&ui);
    ui.tail_snapshot.?.rows = snapshot_rows;
    const composer_rows = ui.tail_composer_rows;
    ui.tail_composer_rows = ui.tail_height; // No row exists for the claimed separator.
    try Denied.check(&ui);
    ui.tail_composer_rows = composer_rows;
    var short: [1]u8 = undefined;
    var short_writer = Io.Writer.fixed(&short);
    try std.testing.expect(!try ui.idleExitBytes(&short_writer));
    try std.testing.expectEqual(@as(usize, 0), short_writer.buffered().len);
    ui.frame = "pending";
    try Denied.check(&ui);
    ui.frame_offset = 1;
    try Denied.check(&ui);
    ui.frame = "";
    ui.frame_offset = 0;
    ui.resize_rescue = "partial";
    try Denied.check(&ui);
    ui.resize_rescue = "";
    const borrowed = ui.menu_history.?.borrowed;
    ui.menu_history.?.borrowed = &.{"borrowed"};
    try Denied.check(&ui);
    ui.menu_history.?.borrowed = borrowed;
    try std.testing.expect(ui.records.items[0].output);
    var conversation_bytes: [2048]u8 = undefined;
    var conversation_writer = Io.Writer.fixed(&conversation_bytes);
    try std.testing.expect(try ui.idleExitBytes(&conversation_writer));
    ui.stop_open = true;
    try Denied.check(&ui);
    ui.stop_open = false;
    _ = try ui.editor.insert("draft");
    try Denied.check(&ui);
    ui.wipeEditor();
    ui.frame_fresh = false;
    try Denied.check(&ui);
    ui.frame_fresh = true;
    ui.abandon_tail = true;
    try Denied.check(&ui);
    ui.abandon_tail = false;
    const pending = try ui.add(.assistant, "undisplayed");
    try Denied.check(&ui);
    ui.removeRecord(pending);
    const old_size = ui.size;
    ui.resize(.{ .columns = 40, .rows = 12 });
    try Denied.check(&ui);
    ui.resize(old_size);
    try Denied.check(&ui); // ABA cannot resurrect cleanup ownership.
}
test "exit blank cleanup places shell after completed short conversation" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    ui.connection.current_fn = FixtureConnection.configuredCurrent;
    try screen.replay("short-prior\r\n");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const user = try ui.add(.user, "short-user");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[user].output);
    const answer = try ui.add(.assistant, "short-answer");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[answer].output);
    ui.notice = "short-footer";
    ui.observeAdvisories();
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[ui.records.items.len - 1].output);
    const history = try std.testing.allocator.dupe(@TypeOf(screen.history[0]), screen.history[0..screen.history_len]);
    defer std.testing.allocator.free(history);
    var bytes: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&bytes);
    try std.testing.expect(try ui.idleExitBytes(&writer));
    try screen.replay(writer.buffered());
    try std.testing.expectEqualSlices(@TypeOf(screen.history[0]), history, screen.history[0..screen.history_len]);
    var last: ?usize = null;
    for (screen.grid[0..screen.rows], 0..) |line, index| {
        if (std.mem.indexOf(u8, &line, "short-footer") != null) last = index;
    }
    try std.testing.expect(last != null);
    try std.testing.expectEqual(last.?, screen.row);
    try screen.replay("\r\nshort-shell");
    try std.testing.expectEqual(last.? + 1, screen.row);
    try std.testing.expect(screen.row < screen.rows - 2);
    for ([_][]const u8{ "short-prior", "short-user", "short-answer", "short-footer", "short-shell" }) |marker|
        try std.testing.expectEqual(@as(usize, 1), screen.count(marker));
}
test "exit blank cleanup retains completed long conversation and native history" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    ui.connection.current_fn = FixtureConnection.configuredCurrent;
    try screen.replay("previous-shell\r\n");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const user = try ui.add(.user, "unique-user-marker");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[user].output);
    var body: Io.Writer.Allocating = .init(a);
    defer body.deinit();
    for (0..80) |i| try body.writer.print("unique-line-{d:0>3}\n", .{i});
    try body.writer.writeAll("paragraph-first\n\nparagraph-last");
    const answer = try ui.add(.assistant, body.written());
    ui.notice = "footer-error-marker";
    ui.observeAdvisories();
    const footer_record = ui.records.items.len - 1;
    for (0..128) |_| {
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        if (ui.records.items[answer].output and ui.records.items[footer_record].output) break;
    }
    try std.testing.expect(ui.records.items[answer].output and ui.records.items[footer_record].output);
    try std.testing.expect(screen.history_len != 0);
    var before_first: ?usize = null;
    var before_last: ?usize = null;
    for (screen.grid[0..screen.rows], 0..) |line, index| {
        if (std.mem.indexOf(u8, &line, "paragraph-first") != null) before_first = index;
        if (std.mem.indexOf(u8, &line, "paragraph-last") != null) before_last = index;
    }
    try std.testing.expect(before_first != null and before_last != null and before_last.? > before_first.? + 1);
    const gap_before = screen.grid[before_first.? + 1];
    const history = try a.dupe(@TypeOf(screen.history[0]), screen.history[0..screen.history_len]);
    defer a.free(history);
    var bytes: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&bytes);
    try std.testing.expect(try ui.idleExitBytes(&writer));
    try screen.replay(writer.buffered());
    try std.testing.expectEqualSlices(@TypeOf(screen.history[0]), history, screen.history[0..screen.history_len]);
    try std.testing.expectEqual(@as(usize, 1), screen.count("unique-user-marker"));
    for (0..80) |i| {
        var marker: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&marker, "unique-line-{d:0>3}", .{i});
        try std.testing.expectEqual(@as(usize, 1), screen.count(name));
    }
    try std.testing.expectEqual(@as(usize, 1), screen.count("paragraph-first"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("paragraph-last"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("footer-error-marker"));
    var first: ?usize = null;
    var last: ?usize = null;
    var footer: ?usize = null;
    for (screen.grid[0..screen.rows], 0..) |line, index| {
        if (std.mem.indexOf(u8, &line, "paragraph-first") != null) first = index;
        if (std.mem.indexOf(u8, &line, "paragraph-last") != null) last = index;
        if (std.mem.indexOf(u8, &line, "footer-error-marker") != null) footer = index;
    }
    try std.testing.expect(first != null and last != null and footer != null);
    try std.testing.expect(last.? > first.? + 1);
    try std.testing.expectEqualSlices(u8, &gap_before, &screen.grid[first.? + 1]);
    try std.testing.expectEqual(footer.?, screen.row);
    try screen.replay("\r\nshell-after-conversation");
    try std.testing.expectEqual(@as(usize, 1), screen.count("shell-after-conversation"));
}
test "natural exit preserves a canonical gap at the scrollback boundary" {
    const a = std.testing.allocator;
    const Screen = @import("../tests/regular_screen.zig").Screen;
    const Locate = struct {
        fn row(screen: *const Screen, marker: []const u8) !usize {
            var result: ?usize = null;
            for (screen.history[0..screen.history_len], 0..) |line, i| {
                if (std.mem.indexOf(u8, &line, marker) != null) {
                    try std.testing.expect(result == null);
                    result = i;
                }
            }
            for (screen.grid[0..screen.rows], 0..) |line, i| {
                if (std.mem.indexOf(u8, &line, marker) != null) {
                    try std.testing.expect(result == null);
                    result = screen.history_len + i;
                }
            }
            return result orelse error.MarkerNotFound;
        }
    };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.natural_flow = true;
    // The bounded screen supports at most 24 rows; use 23 and shorten the
    // second record to keep the styled gap exactly at the viewport boundary.
    ui.size.rows = 23;
    var terminal: terminal_module.Terminal = .{ .fd = -1, .owned = false, .original = undefined, .original_flags = 0, .active = false };
    ui.terminal = &terminal;
    var screen: Screen = .{ .rows = 23 };
    try screen.replay("protected-prior-entry\r\n");
    ui.entry_origin = .{ .size = ui.size, .row = screen.row };
    ui.connection.current_fn = FixtureConnection.configuredCurrent;
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);

    var first: Io.Writer.Allocating = .init(a);
    defer first.deinit();
    for (0..80) |i| {
        if (i != 0) try first.writer.writeAll("\n");
        try first.writer.print("boundary-A{d:0>3}", .{i});
    }
    var second: Io.Writer.Allocating = .init(a);
    defer second.deinit();
    for (0..18) |i| {
        if (i != 0) try second.writer.writeAll("\n");
        try second.writer.print("boundary-B{d:0>3}", .{i});
    }
    const first_record = try ui.add(.assistant, first.written());
    const second_record = try ui.add(.assistant, second.written());
    ui.notice = "boundary-hint";
    ui.observeAdvisories();
    const notice_record = ui.records.items.len - 1;
    for (0..128) |_| {
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        if (ui.records.items[first_record].output and ui.records.items[second_record].output and ui.records.items[notice_record].output) break;
    }
    for (ui.records.items) |record| try std.testing.expect(record.output);
    try std.testing.expect(ui.tail_relative and ui.menu_history != null);
    try std.testing.expect(ui.menu_history.?.above.len > 0);
    // The canonical gap and the no-hint UI separator have identical painted
    // bytes, but only the ACK-owned separator may be reclaimed.
    const styled_gap = "\x1b[0m\x1b[0m\x1b[K";
    try std.testing.expectEqualStrings(styled_gap, ui.menu_history.?.above[0]);
    try std.testing.expect(ui.tail_exit_separator);
    const tail_rows = ui.tail_snapshot.?.rows;
    try std.testing.expect(tail_rows.len > ui.tail_composer_rows);
    try std.testing.expectEqualStrings(styled_gap, tail_rows[tail_rows.len - ui.tail_composer_rows - 1]);
    try std.testing.expect(screen.history_len > 0);
    const protected = screen.history[0];
    try std.testing.expect(std.mem.indexOf(u8, &protected, "protected-prior-entry") != null);
    const a_before = try Locate.row(&screen, "boundary-A079");
    const b_before = try Locate.row(&screen, "boundary-B000");
    try std.testing.expectEqual(a_before + 2, b_before);

    var bytes: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&bytes);
    try std.testing.expect(try ui.idleExitBytes(&writer));
    try screen.replay(writer.buffered());
    try std.testing.expectEqualSlices(u8, &protected, &screen.history[0]);
    try std.testing.expectEqual((try Locate.row(&screen, "boundary-A079")) + 2, try Locate.row(&screen, "boundary-B000"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("boundary-hint"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("?%>"));
    try std.testing.expectEqual(try Locate.row(&screen, "boundary-hint"), screen.history_len + screen.row);
    // Terminal restore emits CRLF after the cleanup; the shell follows it.
    try screen.replay("\r\nboundary-shell");
    try std.testing.expectEqualSlices(u8, &protected, &screen.history[0]);
    try std.testing.expectEqual((try Locate.row(&screen, "boundary-A079")) + 2, try Locate.row(&screen, "boundary-B000"));
    var previous: usize = try Locate.row(&screen, "protected-prior-entry");
    for (0..98) |i| {
        var marker: [32]u8 = undefined;
        const name = if (i < 80)
            try std.fmt.bufPrint(&marker, "boundary-A{d:0>3}", .{i})
        else
            try std.fmt.bufPrint(&marker, "boundary-B{d:0>3}", .{i - 80});
        const current = try Locate.row(&screen, name);
        try std.testing.expect(current > previous);
        previous = current;
    }
    try std.testing.expect((try Locate.row(&screen, "boundary-hint")) > previous);
    try std.testing.expect((try Locate.row(&screen, "boundary-shell")) > (try Locate.row(&screen, "boundary-hint")));
}
test "resume retains long user input in navigable session history" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const input_text = try a.alloc(u8, 65537);
    defer a.free(input_text);
    @memset(input_text, 'x');
    try replayMessages(&ui, std.testing.allocator, &.{.{ .role = .user, .blocks = &.{.{ .text = input_text }} }});
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualSlices(u8, input_text, ui.input_history.target(false).?.text);
}
test "resume startup projects saved text and tool outcomes without replaying reasoning or commands" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try replayMessages(&ui, std.testing.allocator, &.{
        .{ .role = .context, .blocks = &.{.{ .text = "[Earlier context summary — lossy background data]" }} },
        .{ .role = .user, .blocks = &.{.{ .text = "remember this" }} },
        .{ .role = .assistant, .blocks = &.{ .{ .reasoning = "hidden old thought" }, .{ .tool_call = .{ .id = "old-call", .name = "read_file", .arguments = "{\"path\":\"old.txt\"}" } } } },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "old-call", .text = "raw output must not render", .is_error = true, .canceled = true } }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "## Earlier answer" }} },
        .{ .role = .user, .blocks = &.{.{ .text = "/login" }} },
    });
    try std.testing.expect(!ui.busy and ui.future == null and ui.prompt == null and !ui.secret_mode);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("remember this", ui.input_history.entries.items[0]);
    var tools: usize = 0;
    var saw_question = false;
    var saw_answer = false;
    for (ui.records.items) |record| {
        try std.testing.expect(record.kind != .reasoning);
        try std.testing.expect(std.mem.indexOf(u8, record.body.items, "hidden old thought") == null);
        try std.testing.expect(std.mem.indexOf(u8, record.body.items, "raw output must not render") == null);
        if (record.kind == .user and std.mem.eql(u8, record.body.items, "remember this")) saw_question = true;
        if (record.kind == .assistant and std.mem.eql(u8, record.body.items, "## Earlier answer")) saw_answer = true;
        if (record.kind == .tool) {
            tools += 1;
            try std.testing.expect(record.command_row and record.duration_ms == null);
            try std.testing.expectEqual(presentation.Outcome.canceled, record.command_spans.items[0].outcome);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), tools);
    try std.testing.expect(saw_question and saw_answer);
}
test "replayed history turns saved tool results into tool rows with their call caption" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    // The worker seeds one assistant tool_call and one tool_result per saved
    // call; only the caption pairing makes the row name its target.
    ui.applying_history = true;
    try ui.applyEvent(.{ .assistant_committed = &.{
        .{ .tool_call = .{ .id = "call-1", .name = "read_file", .arguments = "{\"path\":\"src/main.zig\"}" } },
    } }, false, true);
    try ui.applyEvent(.{ .tool_result = .{ .id = 1, .name = "read_file", .result = .{ .text = "file body" } } }, false, true);
    ui.applying_history = false;
    var tools: usize = 0;
    for (ui.records.items) |record| {
        if (record.kind != .tool) continue;
        tools += 1;
        try std.testing.expect(record.command_row);
        try std.testing.expect(std.mem.indexOf(u8, record.body.items, "src/main.zig") != null);
        // A saved result body is never replayed as transcript text.
        try std.testing.expect(std.mem.indexOf(u8, record.body.items, "file body") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), tools);
}
test "failed tool rows keep the bounded reason while the target clips" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.applyEvent(.{ .assistant_committed = &.{
        .{ .tool_call = .{ .id = "call-1", .name = "write_file", .arguments = "{\"path\":\"tests/unit/app/session_host_test.zig\",\"content\":\"x\"}" } },
    } }, false, true);
    try ui.applyEvent(.{ .tool_result = .{ .id = 1, .name = "write_file", .result = .{ .text = "AccessDenied", .is_error = true } } }, false, true);
    const record = &ui.records.items[ui.records.items.len - 1];
    try std.testing.expect(record.command_row);
    try std.testing.expect(std.mem.indexOf(u8, record.body.items, "[error] AccessDenied") != null);
    // A narrow row shortens the target, never the reason.
    try record.layout(a, 40);
    const line = record.lines[0];
    try std.testing.expect(std.mem.indexOf(u8, line, "[error] AccessDenied") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "...") != null);
}
test "replayed history keeps file counters and local command output rows" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.applying_history = true;
    try ui.applyEvent(.{ .assistant_committed = &.{
        .{ .tool_call = .{ .id = "call-1", .name = "write_file", .arguments = "{\"path\":\"src/main.zig\",\"content\":\"x\"}" } },
    } }, false, true);
    try ui.applyEvent(.{ .tool_result = .{ .id = 1, .name = "write_file", .result = .{ .text = "written", .file_stats = .{ .changes = .{ .modified = 1, .added = 12, .removed = 3 } } } } }, false, true);
    // A saved !command restores its own tool row plus the bounded output row.
    try ui.applyEvent(.{ .assistant_committed = &.{
        .{ .tool_call = .{ .id = "local_command_7", .name = "bash", .arguments = "{\"command\":\"printf hi\"}" } },
    } }, false, true);
    try ui.applyEvent(.{ .tool_result = .{ .id = 2, .name = "bash", .local = true, .result = .{ .text = "{\"stdout\":\"hi\"}" } } }, false, true);
    ui.applying_history = false;
    var write_rows: usize = 0;
    var output_rows: usize = 0;
    for (ui.records.items) |record| {
        if (record.kind != .tool) continue;
        if (record.command_row) {
            if (std.mem.indexOf(u8, record.body.items, "~1 +12 -3 lines")) |_| write_rows += 1;
        } else if (std.mem.indexOf(u8, record.body.items, "hi") != null) output_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), write_rows);
    try std.testing.expectEqual(@as(usize, 1), output_rows);
}
test "thinking keeps Markdown syntax literal while assistant answers still render it" {
    const a = std.testing.allocator;
    var thinking_record: Record = .{ .kind = .reasoning };
    defer thinking_record.deinit(a);
    try thinking_record.append(a, "# **plan** - `step` | a | b |");
    try thinking_record.layout(a, 80);
    const thinking_lines = thinking_record.lines;
    try std.testing.expectEqual(@as(usize, 1), thinking_lines.len);
    for (thinking_lines, [_][]const u8{"# **plan** - `step` | a | b |"}) |line, literal| {
        try std.testing.expect(std.mem.find(u8, line, literal) != null);
        try std.testing.expect(std.mem.startsWith(u8, line, theme.reset ++ theme.thinking));
        for ([_][]const u8{ theme.heading, theme.inline_code, theme.code, theme.link, theme.strong, theme.muted, theme.success, theme.failure, theme.caution }) |style|
            try std.testing.expect(std.mem.find(u8, line, style) == null);
    }
    var answer: Record = .{ .kind = .assistant };
    defer answer.deinit(a);
    try answer.append(a, "# plan");
    try answer.layout(a, 80);
    const answer_lines = answer.lines;
    try std.testing.expectEqual(@as(usize, 1), answer_lines.len);
    try std.testing.expect(std.mem.find(u8, answer_lines[0], "plan") != null);
    try std.testing.expect(std.mem.find(u8, answer_lines[0], "# plan") == null);
}
test "thinking scrolls in one row and body replaces it without retaining reasoning" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.appendDraft(.reasoning, "think-one\nthink-two\nthink-three\nthink-four");
    try ui.draw();
    try screen.replay(ui.frame);
    for ([_][]const u8{ "think-one", "think-two", "think-three" }) |marker| try std.testing.expect(!screen.visible(marker));
    try std.testing.expect(screen.visible("think-four"));
    // One reasoning row above the separator, fixture notice and composer.
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    try std.testing.expectEqual(@as(usize, 4), ui.frame_height);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(!ui.records.items[0].output);
    try ui.appendDraft(.reasoning, "\nthink-five\nthink-six");
    try ui.draw();
    try screen.replay(ui.frame);
    for ([_][]const u8{ "think-two", "think-three", "think-four", "think-five" }) |marker| try std.testing.expect(!screen.visible(marker));
    try std.testing.expect(screen.visible("think-six"));
    for (screen.history[0..screen.history_len]) |line| try std.testing.expect(std.mem.find(u8, &line, "think-") == null);
    testAcknowledgeFullFrame(&ui);

    try ui.appendDraft(.assistant, "partial-answer\x1b[2J");
    try ui.appendDraft(.reasoning, "late-reasoning");
    try std.testing.expect(ui.reasoning == null);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("Thinking"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("think-"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("late-reasoning"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[2J") == null);
    testAcknowledgeFullFrame(&ui);
    const draft = ui.draft.?;
    try std.testing.expect(!ui.records.items[draft].output);
    // Cancellation keeps only the unfinished visible answer, explicitly marked.
    ui.records.items[draft].interrupted = true;
    ui.draft = null;
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("Interrupted response"));
    testAcknowledgeFullFrame(&ui);
    // PageUp is terminal-native history: it must not regroup completed records
    // or repaint reasoning into this frame.
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[5~", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "History preview") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "think-") == null);
    testAcknowledgeFullFrame(&ui);
}
test "one reasoning row to short answers keeps the composer at its screen row" {
    try text.initLocale();
    for ([_][]const u8{ "answer-one", "answer-one\nanswer-two", "answer-one\nanswer-two\nanswer-three" }) |answer| {
        for ([_]bool{ false, true }) |natural| {
            var cancel: p.Cancellation = .{};
            var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
            defer bridge.deinit();
            var ui = fixtureUi(&bridge, &cancel);
            defer ui.deinit();
            var screen: @import("../tests/regular_screen.zig").Screen = .{};
            ui.natural_flow = natural;
            if (natural) {
                screen.row = 2;
                ui.entry_origin = .{ .size = ui.size, .row = screen.row };
            }
            _ = try ui.add(.user, "short-task");
            _ = try ui.editor.insert("composer-marker");
            ui.mode = .calling_model;
            try ui.draw();
            try screen.replay(ui.frame);
            testAcknowledgeFullFrame(&ui);
            var composer_row = screen.row;
            if (natural) try std.testing.expect(composer_row < screen.rows - 1) else try std.testing.expectEqual(screen.rows - 1, composer_row);
            try std.testing.expect(std.mem.indexOf(u8, &screen.grid[composer_row], "composer-marker") != null);
            try ui.appendDraft(.reasoning, "short-thinking");
            try ui.draw();
            try screen.replay(ui.frame);
            try std.testing.expect(screen.row >= composer_row);
            if (!natural) try std.testing.expectEqual(composer_row, screen.row);
            composer_row = screen.row;
            try std.testing.expect(std.mem.indexOf(u8, &screen.grid[composer_row], "composer-marker") != null);
            try std.testing.expect(screen.visible("short-thinking"));
            testAcknowledgeFullFrame(&ui);
            try ui.appendDraft(.assistant, answer);
            try ui.draw();
            try screen.replay(ui.frame);
            try std.testing.expect(screen.row >= composer_row);
            if (!natural) try std.testing.expectEqual(composer_row, screen.row);
            composer_row = screen.row;
            try std.testing.expect(std.mem.indexOf(u8, &screen.grid[composer_row], "composer-marker") != null);
            try std.testing.expect(screen.visible("answer-one") and !screen.visible("short-thinking"));
            if (std.mem.indexOf(u8, answer, "answer-two") != null) try std.testing.expect(screen.visible("answer-two"));
            if (std.mem.indexOf(u8, answer, "answer-three") != null) try std.testing.expect(screen.visible("answer-three"));
            testAcknowledgeFullFrame(&ui);
            ui.mode = null;
            ui.draft = null;
            try ui.draw();
            try screen.replay(ui.frame);
            try std.testing.expect(screen.row >= composer_row);
            if (!natural) try std.testing.expectEqual(composer_row, screen.row);
            try std.testing.expect(std.mem.indexOf(u8, &screen.grid[screen.row], "composer-marker") != null);
            try std.testing.expectEqual(@as(usize, 0), screen.count("short-thinking"));
            testAcknowledgeFullFrame(&ui);
        }
    }
}
test "reasoning grows from a small acknowledged tail and hides reversibly" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const small_tail = ui.tail_height;
    try std.testing.expect(small_tail != 0 and small_tail < 6);
    try ui.appendDraft(.reasoning, "think-a\nthink-b\nthink-c");
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("think-a") and !screen.visible("think-b"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("think-c"));
    try std.testing.expect(ui.frame_height > small_tail); // Growth, not a hidden reasoning row.
    testAcknowledgeFullFrame(&ui);
    // There was no ACKed row above the small tail to borrow, so every new row
    // grew naturally and no reasoning row entered native history.
    try std.testing.expectEqual(@as(usize, 0), ui.menu_history.?.borrowed.len);
    for (screen.history[0..screen.history_len]) |line| try std.testing.expect(std.mem.find(u8, &line, "think-") == null);
    ui.show_reasoning = false;
    try ui.draw();
    try screen.replay(ui.frame);
    for ([_][]const u8{ "think-a", "think-b", "think-c" }) |marker| try std.testing.expect(!screen.visible(marker));
    testAcknowledgeFullFrame(&ui);
    ui.show_reasoning = true;
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("think-a") and !screen.visible("think-b"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("think-c"));
    testAcknowledgeFullFrame(&ui);
}
test "rolling thinking keeps a bounded incremental tail and can be hidden" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const large = try std.testing.allocator.alloc(u8, 3 * (canonical_mirror_limit / 3 + 10));
    defer std.testing.allocator.free(large);
    for (0..large.len / 3) |i| @memcpy(large[i * 3 ..][0..3], "你");
    try ui.appendDraft(.reasoning, large);
    try ui.appendDraft(.reasoning, "\nnewest-thinking");
    const record = &ui.records.items[ui.reasoning.?];
    const tail = record.tail.?;
    // The record never retains the stream body; the tail owns a bounded window.
    try std.testing.expectEqual(@as(usize, 0), record.body.items.len);
    try std.testing.expectEqual(reasoning_tail_rows, tail.keepRows());
    try std.testing.expectEqual(plain_tail.Limit.none, tail.limitState());
    try std.testing.expect(tail.retainedBytes() <= reasoning_tail_bytes);
    try std.testing.expect(tail.ownedBytes() <= tail.ownedBound());
    try std.testing.expect(tail.retainedSource().len <= reasoning_tail_bytes);
    try std.testing.expect(tail.retainedBytes() < large.len);
    try std.testing.expect(std.mem.endsWith(u8, tail.retainedSource(), "newest-thinking"));
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("newest-thinking"));
    testAcknowledgeFullFrame(&ui);
    // A redraw/layout never re-consumes or extends the retained source. Sparse
    // diffs may omit unchanged glyphs, so assert the replayed screen instead of
    // raw frame bytes.
    const source_len = tail.retainedSource().len;
    const retained = tail.retainedBytes();
    record.invalidate();
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("newest-thinking"));
    try std.testing.expectEqual(source_len, tail.retainedSource().len);
    try std.testing.expectEqual(retained, tail.retainedBytes());
    testAcknowledgeFullFrame(&ui);
    ui.show_reasoning = false;
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("newest-thinking"));
    testAcknowledgeFullFrame(&ui);
    ui.show_reasoning = true;
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("newest-thinking"));
    testAcknowledgeFullFrame(&ui);
    // The bounded/source invariants above were proven on the live owner while
    // it still existed. Cancellation deinitializes that tail, so the proof after
    // the discard must be about ownership, never about dereferencing `tail`.
    ui.discardReasoning(); // Same cancellation cleanup as complete.
    try std.testing.expect(ui.reasoning == null);
    // The fixture holds no other Record, so removal left no reasoning owner and
    // no draft: every retained reasoning byte was released with its tail.
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expect(ui.draft == null);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("newest-thinking"));
    testAcknowledgeFullFrame(&ui);
}
test "live reasoning tail is created at the drawing width before its first layout" {
    try text.initLocale();
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    // draw() never uses the raw terminal width: it reserves one column so the
    // terminal cannot autowrap.
    const draw_columns = @max(1, ui.size.columns -| 1);
    try std.testing.expect(draw_columns != ui.size.columns);
    // One long payload without a newline: at a stale width its first draw would
    // have to reflow rows that were already admitted at the wrong width and
    // could discard them, so the width must be right before any layout.
    var payload: [400]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = 'a' + @as(u8, @intCast(i % 26));
    try ui.appendDraft(.reasoning, &payload);
    const record = &ui.records.items[ui.reasoning.?];
    const tail = record.tail.?;
    try std.testing.expectEqual(draw_columns, tail.columns());
    try expectTailMatchesPlain(tail, draw_columns, &payload);
    const retained = tail.retainedBytes();
    const source_len = tail.retainedSource().len;
    try ui.draw();
    // The first draw agrees instead of resizing the already-admitted rows.
    try std.testing.expectEqual(draw_columns, tail.columns());
    try std.testing.expectEqual(retained, tail.retainedBytes());
    try std.testing.expectEqual(source_len, tail.retainedSource().len);
    try std.testing.expectEqual(draw_columns, record.columns);
    try expectTailMatchesPlain(tail, draw_columns, &payload);
    testAcknowledgeFullFrame(&ui);
}
test "reasoning tail splits UTF8 chunks, wraps, and never resurrects old rows" {
    try text.initLocale();
    const a = std.testing.allocator;
    var record: Record = .{ .kind = .reasoning };
    defer record.deinit(a);
    const body = "forgotten-old-row\none\ntwo\nthree-has-wrap ab中文👍🏽cd";
    const emoji = std.mem.indexOf(u8, body, "👍🏽").?;
    // Split inside the four-byte emoji so the incremental carry must finish it.
    try record.append(a, body[0 .. emoji + 2]);
    try record.append(a, body[emoji + 2 ..]);
    try record.layout(a, 6);
    const tail = record.tail.?;
    try std.testing.expectEqual(@as(usize, 6), tail.columns());
    try std.testing.expect(record.lines.len <= reasoning_tail_rows);
    try std.testing.expectEqual(@as(usize, 1), record.lines.len); // only the last wrapped row
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(a);
    for (record.lines) |line| try joined.appendSlice(a, line);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "👍🏽") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "\u{fffd}") == null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "forgotten-old-row") == null);
    // Reflow only the retained window: the forgotten row cannot come back.
    try record.layout(a, 20);
    try std.testing.expectEqual(@as(usize, 20), tail.columns());
    var reflowed: std.ArrayList(u8) = .empty;
    defer reflowed.deinit(a);
    for (record.lines) |line| try reflowed.appendSlice(a, line);
    try std.testing.expect(std.mem.indexOf(u8, reflowed.items, "forgotten") == null);
    try std.testing.expect(std.mem.indexOf(u8, tail.retainedSource(), "forgotten") == null);
    try std.testing.expect(std.mem.indexOf(u8, reflowed.items, "👍🏽") != null);
}
test "thinking display limit marker is explicit and bounded" {
    try text.initLocale();
    const a = std.testing.allocator;
    var record: Record = .{ .kind = .reasoning };
    defer record.deinit(a);
    try record.append(a, "ok\na");
    for (0..5000) |_| try record.append(a, "\u{0301}");
    try record.layout(a, 80);
    const tail = record.tail.?;
    try std.testing.expectEqual(plain_tail.Limit.cluster, tail.limitState());
    try std.testing.expect(tail.retainedBytes() <= reasoning_tail_bytes);
    try std.testing.expect(record.lines.len <= reasoning_tail_rows + 1);
    const shown = record.lines[record.lines.len -| reasoning_tail_rows..];
    try std.testing.expect(std.mem.find(u8, shown[shown.len - 1], "thinking display limited: cluster; model history unchanged") != null);
}
test "subagent tool progress updates active row and completion only" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const screen = try a.create(@import("../tests/regular_screen.zig").Screen);
    defer a.destroy(screen);
    screen.* = .{};
    ui.mode = .calling_model;
    ui.clock_ms = 1000;
    const key: p.ToolDisplayKey = .{ .generation = 71, .index = 1 };
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 71, .phase = .begin } });
    const fields = @import("../core/tool_preview.zig").Snapshot{ .id = .{ .text = "subagent_1" } };
    try emitToolUi(&ui, .{ .tool_view = .{ .key = key, .name = "get_subagent_result", .fields = fields, .ready = true } });
    try emitToolUi(&ui, .{ .tool_started = .{ .id = 77, .name = "get_subagent_result", .started_ms = 1000, .display_key = key } });
    ui.clock_ms = 2500;
    try emitToolUi(&ui, .{ .tool_view = .{ .key = key, .name = "get_subagent_result", .fields = fields, .ready = true, .subagent_progress = "working" } });
    try std.testing.expectEqualStrings("subagent_1 · working", ui.active_tool.?.caption.label);
    try std.testing.expectEqual(@as(u64, 1000), ui.active_tool.?.started_ms);
    try replayToolFrame(&ui, screen);
    try std.testing.expectEqual(@as(usize, 1), screen.count("subagent_1"));
    try emitToolUi(&ui, .{ .tool_view = .{ .key = .{ .generation = 71, .index = 2 }, .name = "get_subagent_result", .fields = fields, .ready = true, .subagent_progress = "other" } });
    try std.testing.expectEqualStrings("subagent_1 · working", ui.active_tool.?.caption.label);
    try emitToolUi(&ui, .{ .tool_view = .{ .key = key, .name = "get_subagent_result", .fields = fields, .ready = true, .subagent_progress = "latest" } });
    try emitToolUi(&ui, .{ .tool_result = .{ .id = 77, .name = "get_subagent_result", .display_key = key, .result = .{ .text = "done", .duration_ms = 1500 } } });
    try std.testing.expect(ui.active_tool == null);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expect(std.mem.find(u8, ui.records.items[0].body.items, "subagent_1 · latest") != null);
}
test "typed tool row updates in place before execution and uses ready metadata after Bridge clipping" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const screen = try a.create(@import("../tests/regular_screen.zig").Screen);
    defer a.destroy(screen);
    screen.* = .{};
    ui.mode = .calling_model;
    ui.clock_ms = 5000;
    try ui.appendDraft(.reasoning, "transient-reasoning");
    const key: p.ToolDisplayKey = .{ .generation = 9, .index = 3 };
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 9, .phase = .begin } });
    try emitToolUi(&ui, .{ .tool_view = .{ .key = key, .name = "write_file" } });
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.reset ++ "w" ++ theme.muted ++ " write_file") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "transient-reasoning") == null);
    try std.testing.expect(ui.active_tool == null);
    const in_flight = try a.dupe(u8, ui.frame);
    defer a.free(in_flight);
    try emitToolUi(&ui, .{ .tool_view = .{ .key = key, .name = "write_file", .fields = .{ .path = .{ .text = "src/preview.zig" } } } });
    // Updating captions cannot mutate/release a partially written frame.
    try std.testing.expectEqualStrings(in_flight, ui.frame);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    for (0..3) |_| {
        try replayToolFrame(&ui, screen);
        try std.testing.expectEqual(@as(usize, 1), screen.count("src/preview.zig"));
        try std.testing.expectEqual(@as(usize, 0), screen.count("write_file"));
        try std.testing.expect(ui.active_tool == null);
    }
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len); // reasoning only
    const filler = try a.alloc(u8, 70 * 1024);
    defer a.free(filler);
    @memset(filler, 'x');
    const arguments = try std.fmt.allocPrint(a, "{{\"content\":\"PRIVATE_PAYLOAD{s}\",\"path\":\"src/preview.zig\"}}", .{filler});
    defer a.free(arguments);
    const blocks = [_]p.Block{.{ .tool_call = .{ .id = "canonical-write", .name = "write_file", .arguments = arguments } }};
    try emitToolUi(&ui, .{ .assistant_committed = &blocks });
    // The canonical display copy is clipped before path. A typed ready snapshot
    // must remain available without repairing that partial JSON.
    try emitToolUi(&ui, .{ .tool_view = .{ .key = key, .name = "write_file", .fields = .{ .path = .{ .text = "src/preview.zig" } }, .ready = true } });
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 9, .phase = .commit } });
    try replayToolFrame(&ui, screen);
    try std.testing.expect(ui.active_tool == null and ui.records.items.len == 0);
    try std.testing.expectEqual(@as(usize, 1), screen.count("src/preview.zig"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("PRIVATE_PAYLOAD"));
    try emitToolUi(&ui, .{ .tool_started = .{ .id = 77, .name = "write_file", .started_ms = 5000, .display_key = key } });
    ui.clock_ms = 5400;
    try std.testing.expectEqualStrings("src/preview.zig", ui.active_tool.?.caption.label);
    try std.testing.expectEqual(@as(u64, 5000), ui.active_tool.?.started_ms);
    try replayToolFrame(&ui, screen);
    try std.testing.expectEqual(@as(usize, 1), screen.count("src/preview.zig"));
    try emitToolUi(&ui, .{ .tool_result = .{ .id = 77, .name = "write_file", .display_key = key, .result = .{ .text = "not display JSON", .duration_ms = 41, .file_stats = .{ .changes = .{ .added = 3, .removed = 2 } } } } });
    try replayToolFrame(&ui, screen);
    try std.testing.expect(ui.active_tool == null and ui.tool_views.entries.items.len == 0);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(@as(?u64, 41), ui.records.items[0].duration_ms);
    try std.testing.expectEqual(@as(usize, 1), screen.count("src/preview.zig"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("+3"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("file unavailable"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("receiving arguments"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("Preparing write"));
}
test "same-name typed rows keep canonical order and denied calls do not consume another view" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const screen = try a.create(@import("../tests/regular_screen.zig").Screen);
    defer a.destroy(screen);
    screen.* = .{};
    ui.mode = .calling_model;
    const first: p.ToolDisplayKey = .{ .generation = 21, .index = 7 };
    const second: p.ToolDisplayKey = .{ .generation = 21, .index = 2 };
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 21, .phase = .begin } });
    // Arrival/index order is not the final canonical execution order.
    try emitToolUi(&ui, .{ .tool_view = .{ .key = second, .name = "bash", .fields = .{ .command = .{ .text = "echo SECOND" } } } });
    try emitToolUi(&ui, .{ .tool_view = .{ .key = first, .name = "bash", .fields = .{ .command = .{ .text = "echo FIRST" } } } });
    const blocks = [_]p.Block{
        .{ .tool_call = .{ .id = "first", .name = "bash", .arguments = "{\"command\":\"echo FIRST\"}" } },
        .{ .tool_call = .{ .id = "second", .name = "bash", .arguments = "{\"command\":\"echo SECOND\"}" } },
    };
    try emitToolUi(&ui, .{ .assistant_committed = &blocks });
    try emitToolUi(&ui, .{ .tool_view = .{ .key = first, .name = "bash", .fields = .{ .command = .{ .text = "echo FIRST" } }, .ready = true } });
    try emitToolUi(&ui, .{ .tool_view = .{ .key = second, .name = "bash", .fields = .{ .command = .{ .text = "echo SECOND" } }, .ready = true } });
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 21, .phase = .commit } });
    try std.testing.expect(ui.tool_views.entries.items[0].key.eql(first));
    try replayToolFrame(&ui, screen);
    try std.testing.expect(ui.active_tool == null);
    try emitToolUi(&ui, .{ .tool_result = .{ .id = 80, .name = "bash", .display_key = first, .result = .{ .text = "Denied, not executed", .is_error = true } } });
    try std.testing.expect(ui.active_tool == null);
    try std.testing.expectEqual(@as(usize, 1), ui.tool_views.entries.items.len);
    try emitToolUi(&ui, .{ .tool_started = .{ .id = 81, .name = "bash", .display_key = second } });
    try std.testing.expectEqualStrings("echo SECOND", ui.active_tool.?.caption.label);
    try replayToolFrame(&ui, screen);
    try std.testing.expectEqual(@as(usize, 1), screen.count("echo FIRST"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("echo SECOND"));
    try emitToolUi(&ui, .{ .tool_result = .{ .id = 81, .name = "bash", .display_key = second, .result = .{ .text = "done", .duration_ms = 7 } } });
    try replayToolFrame(&ui, screen);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expect(ui.tool_views.entries.items.len == 0);
    try std.testing.expect(std.mem.find(u8, ui.records.items[0].body.items, "echo FIRST") != null);
    try std.testing.expect(std.mem.find(u8, ui.records.items[1].body.items, "echo SECOND") != null);
    const next: p.ToolDisplayKey = .{ .generation = 22, .index = 7 };
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 22, .phase = .begin } });
    try emitToolUi(&ui, .{ .tool_view = .{ .key = next, .name = "read_file", .fields = .{ .path = .{ .text = "canceled-preview.txt" } } } });
    try replayToolFrame(&ui, screen);
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 21, .phase = .discard } });
    try std.testing.expectEqual(@as(usize, 1), ui.tool_views.entries.items.len);
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 22, .phase = .discard } });
    try replayToolFrame(&ui, screen);
    try std.testing.expect(ui.tool_views.entries.items.len == 0 and ui.records.items.len == 2);
    try std.testing.expectEqual(@as(usize, 0), screen.count("canceled-preview.txt"));
}
test "canonical caption keeps valid detail omitted by conservative preview extraction" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const identity: p.ToolDisplayKey = .{ .generation = 30, .index = 0 };
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 30, .phase = .begin } });
    try emitToolUi(&ui, .{ .assistant_committed = &.{.{ .tool_call = .{ .id = "memory-list", .name = "memory", .arguments = "{\"action\":\"list\",\"topic\":null}" } }} });
    try emitToolUi(&ui, .{ .tool_view = .{ .key = identity, .name = "memory", .ready = true } });
    try emitToolUi(&ui, .{ .tool_started = .{ .id = 1, .name = "memory", .display_key = identity } });
    try std.testing.expectEqualStrings("list core/index", ui.active_tool.?.caption.label);
    try std.testing.expectEqual(ui.tool_calls.items.items.len, ui.tool_calls.cursor);
}
test "bounded tool window keeps the first actual execution visible in a full batch" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size.rows = 10;
    ui.mode = .calling_model;
    const screen = try a.create(@import("../tests/regular_screen.zig").Screen);
    defer a.destroy(screen);
    screen.* = .{ .rows = 10 };
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 31, .phase = .begin } });
    for (0..64) |i| try emitToolUi(&ui, .{ .tool_view = .{
        .key = .{ .generation = 31, .index = i },
        .name = "bash",
        .fields = .{ .command = .{ .text = if (i == 0) "FIRST_ACTIVE_TOOL" else "queued" } },
        .ready = true,
    } });
    try emitToolUi(&ui, .{ .tool_views = .{ .generation = 31, .phase = .commit } });
    try emitToolUi(&ui, .{ .tool_started = .{ .id = 1, .name = "bash", .display_key = .{ .generation = 31, .index = 0 } } });
    try replayToolFrame(&ui, screen);
    try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
    try std.testing.expect(screen.visible("FIRST_ACTIVE_TOOL"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("FIRST_ACTIVE_TOOL"));
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
}
test "raw write deltas alone never display JSON or invent execution" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.mode = .calling_model;
    const host = bridge.host();
    const previews = [_]r.Event{
        .{ .tool_preview = .{ .index = 2, .arguments = "", .write_file = true, .argument_bytes = 0 } },
        .{ .tool_preview = .{ .index = 2, .arguments = "RAW_WRITE_BYTES", .write_file = true, .argument_bytes = 4096 } },
    };
    for (previews) |event_| {
        try host.emit_fn(host.context, event_, &cancel);
        var item = bridge.pop().?;
        defer item.deinit();
        try ui.event(item);
        try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
        try std.testing.expect(ui.active_tool == null);
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, "Preparing write") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "receiving arguments") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "received") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "RAW_WRITE_BYTES") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "+3") == null);
        testAcknowledgeFullFrame(&ui);
    }
    const events = [_]r.Event{
        .{ .assistant_committed = &.{.{ .tool_call = .{ .id = "write-2", .name = "write_file", .arguments = "{\"path\":\"preview.txt\"}" } }} },
        .{ .tool_started = .{ .id = 7, .name = "write_file" } },
        .{ .tool_result = .{ .id = 7, .name = "write_file", .result = .{ .text = "written", .file_stats = .{ .changes = .{ .added = 3, .removed = 2 } } } } },
    };
    for (events, 0..) |event_, index| {
        try host.emit_fn(host.context, event_, &cancel);
        var item = bridge.pop().?;
        defer item.deinit();
        try ui.event(item);
        if (index < 2) try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, "Preparing write") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "receiving arguments") == null);
        if (index == 0) {
            try std.testing.expect(ui.active_tool == null);
            try std.testing.expect(std.mem.find(u8, ui.frame, "preview.txt") == null);
        } else if (index == 1) {
            try std.testing.expect(ui.active_tool != null);
            try std.testing.expect(std.mem.find(u8, ui.frame, theme.tool_icon_pulse[0] ++ "w" ++ theme.muted ++ " preview.txt") != null);
            try std.testing.expect(std.mem.find(u8, ui.frame, "+3") == null);
        } else {
            try std.testing.expect(ui.active_tool == null);
            try std.testing.expect(std.mem.find(u8, ui.frame, "preview.txt") != null);
            try std.testing.expect(std.mem.find(u8, ui.frame, "+3") != null);
        }
        testAcknowledgeFullFrame(&ui);
    }
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expect(std.mem.find(u8, ui.records.items[0].body.items, "+3") != null);
    try std.testing.expect(std.mem.find(u8, ui.records.items[0].body.items, "-2") != null);
    const pause_result: r.Terminal = .{ .status = .paused, .detail = error.RoundLimit };
    ui.last_terminal = pause_result;
    ui.notice = Ui.terminalNotice(pause_result);
    ui.queueTerminalNotice(pause_result);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const notice = try ui.hint(arena.allocator(), ui.connection.current());
    try std.testing.expectEqualStrings("Not configured: /login, then /model", notice);
    for ([_][]const u8{ "Paused", "round limit", "RoundLimit", "preview.txt", "RAW_WRITE_BYTES" }) |forbidden|
        try std.testing.expect(std.mem.find(u8, notice, forbidden) == null);
    try std.testing.expectEqual(NoticeLevel.failure, ui.records.items[ui.records.items.len - 1].notice_level);
    try std.testing.expectEqualStrings(Ui.terminalNotice(pause_result), ui.records.items[ui.records.items.len - 1].body.items);
    try std.testing.expect(std.mem.find(u8, ui.records.items[ui.records.items.len - 1].body.items, "RoundLimit") == null);
}
test "tool animation is transient and raw tool JSON never enters displayed records" {
    for ([_][]const u8{ "memory", "bash", "read_file", "write_file" }) |name| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.mode = .executing_tool;
        const host = bridge.host();
        const arguments = if (std.mem.eql(u8, name, "bash")) "{\"command\":\"date\"}" else if (std.mem.eql(u8, name, "memory")) "{\"action\":\"read\",\"topic\":\"core\"}" else "{\"path\":\"src/example.zig\"}";
        try ui.captureToolCaptions(&.{.{ .tool_call = .{ .id = "fixture-call", .name = name, .arguments = arguments } }});
        try host.emit_fn(host.context, .{ .tool_started = .{ .id = 7, .name = name } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, activity.spinner(0)) != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, if (std.mem.eql(u8, name, "bash")) "date" else if (std.mem.eql(u8, name, "memory")) "read core" else "src/example.zig") != null);
        const icon = if (std.mem.eql(u8, name, "bash")) ">" else if (std.mem.eql(u8, name, "memory")) "m" else if (std.mem.eql(u8, name, "read_file")) "r" else "w";
        const tool_prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}{s}", .{ theme.toolIconColor(0), icon, theme.muted });
        defer std.testing.allocator.free(tool_prefix);
        try std.testing.expect(std.mem.find(u8, ui.frame, tool_prefix) != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "#7") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "Running memory") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "Running bash") == null);
        testAcknowledgeFullFrame(&ui);
        ui.clock_ms = 120;
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, activity.spinner(120)) != null);
        testAcknowledgeFullFrame(&ui);
        try host.emit_fn(host.context, .{ .tool_preview = .{ .index = 0, .arguments = "{\"hidden-tool-argument\":1}" } }, &cancel);
        item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        try host.emit_fn(host.context, .{ .tool_result = .{ .id = 7, .name = name, .result = .{ .text = "{\"hidden-tool-output\":1}" } } }, &cancel);
        item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        try std.testing.expect(ui.active_tool == null);
        try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
        try ui.replaceCommitted(&.{.{ .text = "{\"requested-answer\":1}" }}, false, true);
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, "hidden-tool-") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "requested-answer") != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "completed") == null);
        testAcknowledgeFullFrame(&ui);
    }
}
test "first pending tool follows user gap then tools stay contiguous" {
    for ([_][]const u8{ "bash", "read_file", "write_file", "memory" }) |name| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        _ = try ui.add(.user, "tool-user-end");
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        const args = if (std.mem.eql(u8, name, "bash")) "{\"command\":\"target-one\"}" else if (std.mem.eql(u8, name, "memory")) "{\"action\":\"read\",\"topic\":\"target-one\"}" else "{\"path\":\"target-one\"}";
        try ui.captureToolCaptions(&.{.{ .tool_call = .{ .id = "gap-one", .name = name, .arguments = args } }});
        ui.active_tool = .{ .id = 1, .caption = try ui.nextToolCaption(name), .started_ms = 0 };
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "tool-user-end", "target-one");
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
        try ui.toolCompleted(ui.active_tool.?.caption, .{ .text = "{}" });
        ui.clearActiveTool();
        try ui.draw();
        try screen.replay(ui.frame);
        try expectTranscriptGap(&screen, "tool-user-end", "target-one");
        testAcknowledgeFullFrame(&ui);
        const second: presentation.Caption = .{ .kind = .read, .label = "target-two" };
        ui.active_tool = .{ .id = 2, .caption = .{ .kind = .read, .label = try std.testing.allocator.dupe(u8, second.label) }, .started_ms = 0 };
        try ui.draw();
        try screen.replay(ui.frame);
        var first_row: ?usize = null;
        var second_row: ?usize = null;
        for (screen.grid, 0..) |line, row| {
            if (std.mem.indexOf(u8, &line, "target-one") != null) first_row = row;
            if (std.mem.indexOf(u8, &line, "target-two") != null) second_row = row;
        }
        try std.testing.expect(first_row != null and second_row != null);
        try std.testing.expectEqual(first_row.? + 1, second_row.?);
        // Two released tool rows above the one-row tool body and hinted footer.
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
    }
}
test "same batch bash calls own contiguous pending and result rows with FIFO labels" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .assistant_committed = &.{
        .{ .tool_call = .{ .id = "one", .name = "bash", .arguments = "{\"command\":\"date\"}" } },
        .{ .tool_call = .{ .id = "two", .name = "bash", .arguments = "{\"command\":\"pwd\"}" } },
    } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    // A preparation failure without started consumes only its own caption.
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 1, .name = "bash", .result = .{ .text = "hidden-error-json", .is_error = true } } }, &cancel);
    item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try host.emit_fn(host.context, .{ .tool_started = .{ .id = 2, .name = "bash" } }, &cancel);
    item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try std.testing.expectEqualStrings("pwd", ui.active_tool.?.caption.label);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    var failed_row: ?usize = null;
    var pending_row: ?usize = null;
    for (screen.grid, 0..) |line, row| {
        if (std.mem.find(u8, &line, "date [error]") != null) failed_row = row;
        if (std.mem.find(u8, &line, "pwd") != null) pending_row = row;
    }
    try std.testing.expect(failed_row != null and pending_row != null);
    try std.testing.expectEqual(failed_row.? + 1, pending_row.?);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
    try host.emit_fn(host.context, .{ .tool_result = .{ .id = 2, .name = "bash", .result = .{ .text = "hidden-output-json" } } }, &cancel);
    item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqualStrings("> date [error]", ui.records.items[0].body.items);
    try std.testing.expectEqualStrings("> pwd", ui.records.items[1].body.items);
    try ui.draw();
    try std.testing.expect(ui.records.items[0].output);
    try std.testing.expect(!ui.records.items[0].pending_output);
    try std.testing.expect(ui.records.items[1].pending_output);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items[0].lines.len);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items[1].lines.len);
    try std.testing.expect(std.mem.find(u8, ui.frame, " date [error]") == null); // The previous result is not rewritten.
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.reset ++ theme.success ++ ">" ++ theme.muted ++ " pwd") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "hidden-") == null);
    try screen.replay(ui.frame);
    failed_row = null;
    pending_row = null;
    for (screen.grid, 0..) |line, row| {
        if (std.mem.find(u8, &line, "date [error]") != null) failed_row = row;
        if (std.mem.find(u8, &line, "> pwd") != null) pending_row = row;
    }
    try std.testing.expect(failed_row != null and pending_row != null);
    try std.testing.expectEqual(failed_row.? + 1, pending_row.?);
    // Both captions are contiguous at rows 0 and 1, so the second one is the
    // last body row; the separator, hint and composer follow it unchanged and
    // the cursor lands exactly three rows below the pending caption.
    try std.testing.expectEqual(pending_row.? + 3, screen.row);
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, " date [error]") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, " pwd") == null);
}
test "complete canonical tails beyond the old block cap prevent a false final heading" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const old_block_limit = 256;
    var blocks: [old_block_limit + 1]p.Block = @splat(.{ .text = "" });
    blocks[0] = .{ .text = "intermediate-body" };
    blocks[old_block_limit] = .{ .tool_call = .{ .id = "tail-tool", .name = "bash", .arguments = "{\"command\":\"pwd\"}" } };
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .assistant_committed = &blocks }, &cancel);
    var item = bridge.pop().?;
    defer item.deinit();
    try std.testing.expect(!item.display_truncated and item.canonical_complete);
    try std.testing.expectEqual(blocks.len, item.event.assistant_committed.len);
    try std.testing.expectEqualStrings("tail-tool", item.event.assistant_committed[old_block_limit].tool_call.id);
    try ui.event(item);
    try std.testing.expect(ui.draft == null and ui.records.items.len == 1);
    try std.testing.expectEqual(Kind.assistant, ui.records.items[0].kind);
    try std.testing.expectEqualStrings("intermediate-body", ui.records.items[0].body.items);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "intermediate-body") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Final answer") == null);
    testAcknowledgeFullFrame(&ui);
}
test "tool only reasoning only and empty canonical bodies remove a previously visible draft" {
    for ([_]p.Block{
        .{ .tool_call = .{ .id = "id", .name = "bash", .arguments = "{}" } },
        .{ .reasoning = "not-visible-canonical" },
        .{ .text = "" },
    }) |block| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        _ = try ui.add(.user, "retained-user");
        try ui.appendDraft(.assistant, "provisional-body");
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        try ui.replaceCommitted(&.{block}, false, true);
        try std.testing.expect(ui.draft == null and ui.records.items.len == 1);
        try std.testing.expectEqual(Kind.user, ui.records.items[0].kind);
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, "Final answer") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "provisional-body") == null);
        testAcknowledgeFullFrame(&ui);
    }
}
test "file captions are contiguous but separated from final prose and percent context changes by value" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const call = try shared.tools.Call.init(std.testing.allocator, "write_file", "{\"path\":\"src/main.zig\",\"content\":\"do-not-show-body\"}");
    defer call.deinit(std.testing.allocator);
    const cap = try presentation.fromCall(std.testing.allocator, call);
    defer cap.deinit(std.testing.allocator);
    try ui.toolCompleted(cap, .{ .text = "raw-json-must-stay-hidden", .file_stats = .{ .changes = .{ .modified = 1, .added = 2, .removed = 3 } } });
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .context_snapshot = .{ .tokens = 16384, .limit = 32768 } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try ui.replaceCommitted(&.{.{ .text = "final-body-marker" }}, false, true);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "w" ++ theme.muted ++ " src/main.zig  ~1 " ++ theme.diff_added ++ "+2" ++ theme.muted ++ " " ++ theme.diff_removed ++ "-3" ++ theme.muted ++ " lines") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "raw-json-must-stay-hidden") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "do-not-show-body") == null);
    // Keep exact palette assertions independent of the already-established
    // bold prefix and its reset before editor text.
    const color_frame = try std.mem.replaceOwned(u8, std.testing.allocator, ui.frame, "\x1b[1m", "");
    defer std.testing.allocator.free(color_frame);
    try std.testing.expect(std.mem.find(u8, color_frame, "(" ++ theme.reset ++ "fixture" ++ theme.reset ++ ") " ++ theme.failure ++ "50.0%" ++ theme.reset ++ ">" ++ theme.reset ++ " ") != null);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("Final answer") and screen.visible("final-body-marker"));
    try expectTranscriptGap(&screen, "src/main.zig", "final-body-marker");
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 0), screen.count("=> Final answer"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("final-body-marker"));
    testAcknowledgeFullFrame(&ui);
}
test "committed large Markdown caches stay untouched across resize and PageUp" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var source: Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    for ([_][]const u8{ "once-history-marker", "second-history-marker" }) |marker| {
        source.clearRetainingCapacity();
        try source.writer.print("{s}\n\n", .{marker});
        for (0..64) |_| try source.writer.writeAll("**wide paragraph** with enough words to wrap at the smaller preview width.\n\n");
        _ = try ui.add(.assistant, source.written());
    }
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    // Active bodies are incremental: acknowledged source is gone, so there is
    // no committed cache to preserve. What matters is that nothing is replayed.
    try std.testing.expectEqual(@as(usize, 0), ui.records.items[0].stream.?.windowBytes() -| ui.records.items[0].stream.?.pendingBytes());
    ui.resize(.{ .columns = 41, .rows = 24 });
    try ui.draw();
    inline for (0..2) |i| {
        const record = &ui.records.items[i];
        try std.testing.expect(record.output or record.stream != null);
    }
    try std.testing.expect(std.mem.find(u8, ui.frame, "history-marker") == null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    // No program history preview path exists: committed records are never
    // re-laid out or replayed for a PageUp or a resize.
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    for (0..2) |_| try ui.parser.feed("\x1b[5~", sink);
    try ui.draw();
    inline for (0..2) |i| {
        try std.testing.expect(ui.records.items[i].stream != null);
    }
    try std.testing.expect(std.mem.find(u8, ui.frame, "history-marker") == null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    // Screen is only a fixed-grid transcript counter, not a resize/reflow oracle.
    try std.testing.expectEqual(@as(usize, 1), screen.count("once-history-marker"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("second-history-marker"));
}
test "growing and bulk committed frames synchronize before scrolling and release before cursor ACK" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var source: Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    for (0..20) |_| try source.writer.writeAll("older-row\n");
    try source.writer.writeAll("last-older-row");
    _ = try ui.add(.assistant, source.written());
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 3), ui.tail_height);

    try ui.appendDraft(.assistant, "growth-draft-marker\nsecond-draft-line");
    try ui.draw();
    try std.testing.expect(!ui.frame_sparse);
    try expectSynchronizedFrame(ui.frame);
    // This expansion scrolls three rows. Supporting terminals must not publish
    // the intermediate state where draft rows have overwritten the old footer.
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 6), ui.tail_height);

    source.clearRetainingCapacity();
    for (0..64) |i| try source.writer.print("committed-{d}\n\n", .{i});
    try ui.replaceCommitted(&.{.{ .text = source.written() }}, false, true);
    try ui.draw();
    try expectSynchronizedFrame(ui.frame);
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 1), screen.count("committed-63"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("growth-draft-marker"));
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    testAcknowledgeFullFrame(&ui);

    try ui.draw();
    try std.testing.expect(ui.frame_sparse);
    try expectSynchronizedFrame(ui.frame);
    try std.testing.expect(std.mem.find(u8, ui.frame, "committed-") == null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
}
test "bulk frames repaint before erasing stale line suffixes" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    // Cover shrinking/empty rows as well as an almost-full-width replacement.
    const almost_full: [79]u8 = @splat('x');
    for ([_][]const u8{ "new", "", &almost_full, "\x1b[1mbold\x1b[0m" }) |line| {
        out.clearRetainingCapacity();
        try putStyled(&out.writer, 1, line);
        const bytes = out.written();
        const erase = std.mem.find(u8, bytes, "\x1b[K") orelse return error.MissingSuffixErase;
        try std.testing.expectEqual(@as(usize, 4 + line.len + 4), erase);
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try screen.replay("previous long content\r");
        try screen.replay(bytes[0..erase]); // 正文先于擦除出现，行尾旧内容不提前消失。
        const replaced = screen.grid[0];
        const column = screen.col;
        try screen.replay(bytes[erase..]);
        try std.testing.expectEqualSlices(u8, replaced[0..column], screen.grid[0][0..column]);
        for (screen.grid[0][column..]) |cell| try std.testing.expectEqual(@as(u8, ' '), cell);
    }

    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try seedPriorBottom(&screen);
    for (0..32) |i| {
        var buffer: [128]u8 = undefined;
        const chunk = try std.fmt.bufPrint(&buffer, "bulk-{d} **changing body** with several words to fill the viewport.\n\n", .{i});
        try ui.appendDraft(.assistant, chunk);
        ui.clock_ms = @intCast(i * 33);
        try ui.draw();
        // Inspect the candidate before finishFrame releases it, including growth.
        try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[2K") == null);
        try screen.replay(ui.frame);
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        testAcknowledgeFullFrame(&ui);
    }
    try std.testing.expect(screen.visible("bulk-31"));
}
test "stable large table body is not erased or reprinted for a footer animation tick" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true; // No worker: simulate only the renderer-owned pulse.
    _ = try ui.add(.user, "owned request");
    var source: Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("| Key | Description |\n| --- | --- |\n");
    for (0..64) |i| try source.writer.print("| row-{d} | bounded table cell |\n", .{i});
    try ui.appendDraft(.assistant, source.written());
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const before = screen.grid;
    ui.clock_ms = 80;
    try ui.draw();
    // Only the animated composer changed. A completed body must not disappear
    // in a separate blank pass or be rewritten solely for a footer pulse.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ui.frame, "\x1b[K"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "row-") == null);
    try screen.replay(ui.frame);
    for (0..23) |row| try std.testing.expectEqualSlices(u8, &before[row], &screen.grid[row]);
    try std.testing.expectEqual(@as(usize, 23), screen.row);
    testAcknowledgeFullFrame(&ui);
}
test "one-pass transcript separators erase acknowledged approval preview before committing records" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.user, "first request");
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = "GHOST-preview-1\nGHOST-preview-2\nGHOST-preview-3\nGHOST-preview-4\nGHOST-preview-5\nGHOST-preview-6" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(screen.visible("Approval #1"));
    try std.testing.expect(ui.tail_snapshot == null);
    // The actual loop can answer and receive results before its next draw slot.
    ui.clearPermission();
    _ = try ui.add(.tool, "completed-tool-result");
    _ = try ui.add(.user, "next-user-record");
    _ = try ui.add(.assistant, "short-canonical-record");
    try ui.draw();
    try std.testing.expect(!ui.frame_sparse and ui.frame_tail_snapshot != null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), screen.count("Approval #1"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("GHOST-preview"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("completed-tool-result"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("next-user-record"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("short-canonical-record"));
    try std.testing.expectEqual(screen.rows - 1, screen.row);
}
test "long approval Escape restores acknowledged conversation without blank screen or replay" {
    try text.initLocale();
    for (0..4) |scenario| {
        const pending_canonical = scenario & 1 != 0;
        const cancel_during_frame = scenario & 2 != 0;
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        _ = try ui.add(.user, "owned request before long approval");
        var body: Io.Writer.Allocating = .init(std.testing.allocator);
        defer body.deinit();
        for (0..18) |i| try body.writer.print("PRIOR-RESPONSE-{d:0>2}  \n", .{i});
        _ = try ui.add(.assistant, body.written());
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expect(screen.visible("PRIOR-RESPONSE-17"));
        const history_before = screen.history_len;
        const pending_index = ui.records.items.len;
        if (pending_canonical) {
            _ = try ui.add(.user, "new short request");
            _ = try ui.add(.assistant, "PENDING-CANONICAL-RESPONSE");
        }
        body.clearRetainingCapacity();
        for (0..64) |i| try body.writer.print("CANCEL-GHOST-PREVIEW-{d}: synthetic 中文\n", .{i});
        ui.busy = true;
        ui.mode = .awaiting_permission;
        const host = bridge.host();
        try host.emit_fn(host.context, .{ .permission = .{ .id = 14, .tool_name = "bash", .description = body.written() } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        // Only the first forward-growing confirmation may scroll the native
        // history; repeated redraws must not replay any rows.
        const old_tail_height = ui.tail_height;
        var approval_history: usize = 0;
        for (0..8) |tick| {
            try ui.draw();
            const first_growth = ui.frame_height -| old_tail_height;
            if (cancel_during_frame and tick == 7) {
                const split = std.mem.indexOf(u8, ui.frame, "\r\n").? + 2;
                try screen.replay(ui.frame[0..split]);
                ui.requestCancel(); // Cancel while the last preview is in flight.
                try screen.replay(ui.frame[split..]);
            } else try screen.replay(ui.frame);
            if (!pending_canonical) {
                if (tick == 0) {
                    try std.testing.expectEqual(history_before + first_growth, screen.history_len);
                    approval_history = screen.history_len;
                } else try std.testing.expectEqual(approval_history, screen.history_len);
            }
            testAcknowledgeFullFrame(&ui);
        }
        try std.testing.expect(screen.visible("Approval #14"));
        const record_count = ui.records.items.len;
        if (pending_canonical) try std.testing.expect(!ui.records.items[pending_index].output);
        if (!cancel_during_frame) ui.requestCancel(); // Empty-draft/no-queue Esc.
        try std.testing.expect(cancel.isRequested());
        try std.testing.expect(ui.permission == null);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        if (!screen.visible("PRIOR-RESPONSE-17")) std.debug.print("APPROVAL_CANCEL pending_canonical={any} history_delta={d} retained_prior={d} prior_visible=false\n", .{ pending_canonical, screen.history_len -| history_before, screen.count("PRIOR-RESPONSE-") });
        try std.testing.expect(screen.visible("PRIOR-RESPONSE-17"));
        try std.testing.expectEqual(@as(usize, 18), screen.count("PRIOR-RESPONSE-"));
        for (0..18) |i| {
            var marker: [32]u8 = undefined;
            const value = try std.fmt.bufPrint(&marker, "PRIOR-RESPONSE-{d:0>2}", .{i});
            try std.testing.expectEqual(@as(usize, 1), screen.count(value));
        }
        try std.testing.expectEqual(@as(usize, 0), screen.count("Approval #14"));
        try std.testing.expectEqual(@as(usize, 0), screen.count("CANCEL-GHOST-PREVIEW"));
        try std.testing.expectEqual(record_count, ui.records.items.len);
        if (pending_canonical) {
            try std.testing.expect(ui.records.items[pending_index].output);
            try std.testing.expect(screen.visible("PENDING-CANONICAL-RESPONSE"));
            try std.testing.expectEqual(@as(usize, 1), screen.count("PENDING-CANONICAL-RESPONSE"));
        } else try std.testing.expectEqual(approval_history, screen.history_len);
    }
}
test "inline approval never covers transcript by borrowing" {
    try text.initLocale();
    for (0..4) |scenario| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        _ = try ui.add(.assistant, "owned-0\nowned-1\nowned-2\nowned-3\nowned-4\nowned-5");
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try ui.draw();
        if (scenario == 0) try screen.replay(ui.frame);
        if (scenario == 1) ui.frame_fresh = false;
        testAcknowledgeFullFrame(&ui);
        if (scenario == 2) {
            ui.resize(.{ .columns = 79, .rows = 24 });
            ui.resize(.{ .columns = 80, .rows = 24 });
        }
        if (scenario == 3) ui.size.columns = 70;
        var description: Io.Writer.Allocating = .init(std.testing.allocator);
        defer description.deinit();
        for (0..32) |i| try description.writer.print("owned synthetic approval line {d}\n", .{i});
        const host = bridge.host();
        try host.emit_fn(host.context, .{ .permission = .{ .id = 14, .tool_name = "bash", .description = description.written() } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        try ui.draw();
        try std.testing.expectEqual(@as(usize, 0), ui.frame_borrow_rows);
        try std.testing.expectEqual(@as(usize, 0), ui.frame_menu_history.?.borrowed.len);
        try std.testing.expect(ui.displayed_permission == null);
        if (scenario == 0) {
            try screen.replay(ui.frame);
            for ([_][]const u8{ "owned-0", "owned-1", "owned-2", "owned-3", "owned-4", "owned-5" }) |marker| {
                try std.testing.expect(screen.visible(marker));
                try std.testing.expectEqual(@as(usize, 1), screen.count(marker));
            }
        }
        testAcknowledgeFullFrame(&ui);
    }
}
test "approval waiting pulse never adds repeated prompts to native scrollback" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    ui.clock_ms = 80;
    ui.dirty = false;
    ui.animate();
    try std.testing.expect(ui.dirty); // Ordinary execution still animates.
    ui.mode = .awaiting_permission;
    _ = try ui.add(.user, "owned request before approval");
    _ = try ui.add(.assistant, "owned assistant before approval");
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    var source: Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    for (0..125) |i| try source.writer.print("synthetic-step-{d}: Chinese 中文注释 only; abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz\n", .{i});
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 14, .tool_name = "bash", .description = source.written() } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const history_before = screen.history_len;
    try std.testing.expect(screen.visible("Approval #14"));
    ui.dirty = false;
    for (2..66) |tick| {
        ui.clock_ms = tick * 80;
        ui.animate();
        try std.testing.expect(!ui.dirty); // No key/event: no repeated preview.
        // Explicit redraws (input/events) must still preserve tail ownership.
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(history_before, screen.history_len);
        try std.testing.expectEqual(@as(usize, 1), screen.count("Approval #14"));
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        try std.testing.expectEqual(@as(?u64, 14), ui.displayed_permission);
    }
    ui.dirty = true;
    ui.clock_ms += 80;
    ui.animate();
    try std.testing.expect(ui.dirty); // Do not swallow a real event's repaint.
    ui.clearPermission();
    ui.dirty = false;
    ui.clock_ms += 80;
    ui.animate();
    try std.testing.expect(ui.dirty); // Animation resumes once approval ends.
    try std.testing.expect(!cancel.isRequested());
}
test "ordinary redraws coalesce from the previous draw start while input stays urgent" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    // Nothing pending: no idle redraw and no cadence wake-up is requested.
    ui.dirty = false;
    try std.testing.expect(!ui.drawReady() and !ui.drawDue());

    // Keyboard input is urgent but still waits for an already-started frame.
    ui.clock_ms = 1000;
    ui.urgent_draw = true;
    ui.dirty = true;
    try std.testing.expect(ui.drawDue());
    ui.frame = "partial";
    try std.testing.expect(!ui.drawDue());
    ui.frame = "";
    try ui.draw();
    try std.testing.expectEqual(@as(u64, 1000), ui.last_draw_ms);
    // Only staging that fresh draw consumes the urgent bit; draw() itself keeps
    // it so a caller cannot lose input without writing a frame.
    try std.testing.expect(ui.urgent_draw);
    ui.urgent_draw = false;
    testAcknowledgeFullFrame(&ui);
    ui.dirty = false;

    // Ordinary work waits only for the rest of the interval, never a new one.
    ui.clock_ms = 1005;
    ui.dirty = true;
    try std.testing.expect(!ui.drawDue());
    try std.testing.expectEqual(@as(u16, 3), ui.cadenceWaitMs());
    ui.clock_ms = 1007;
    try std.testing.expect(!ui.drawDue());
    try std.testing.expectEqual(@as(u16, 1), ui.cadenceWaitMs());
    ui.clock_ms = 1008;
    try std.testing.expect(ui.drawDue());

    // Unproven geometry keeps its own inhibited state and never enters the
    // cadence by timer, even when input is urgent.
    ui.resize_waiting = true;
    ui.urgent_draw = true;
    try std.testing.expect(!ui.drawReady() and !ui.drawDue());
}
test "canonical stream commit drains long finalized paragraphs by complete prefix" {
    for ([_]u16{ 80, 187 }) |columns| for ([_]bool{ false, true }) |newline| for ([_]bool{ false, true }) |natural| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        var terminal: terminal_module.Terminal = .{ .fd = -1, .owned = false, .original = undefined, .original_flags = 0, .active = false };
        ui.terminal = &terminal;
        ui.size = .{ .columns = columns, .rows = 39 };
        ui.natural_flow = natural;
        const source = try testLongCanonicalSource(std.testing.allocator, newline);
        defer std.testing.allocator.free(source);
        const rendered = try markdown.render(std.testing.allocator, source, .{ .columns = columns - 1, .max_lines = 8192 });
        defer markdown.release(std.testing.allocator, rendered);
        try std.testing.expect(!rendered.truncated);
        var drawn: usize = 0;
        try ui.replaceCommitted(&.{.{ .text = source }}, false, true);
        const index = ui.records.items.len - 1;
        const body = ui.records.items[index].stream.?;
        var saw_preview = false;
        var frames: usize = 0;
        while (!ui.records.items[index].output and frames < 100) : (frames += 1) {
            const old_base = body.base;
            const old_written = ui.records.items[index].stream_written;
            try ui.draw();
            try std.testing.expect(body.arena.queryCapacity() > 0);
            const entry = ui.frame_records[0];
            const expected = body.releaseLimit(body.visibleRows().len);
            try std.testing.expectEqual(expected, entry.stream_rows);
            if (expected < body.visibleRows().len) {
                saw_preview = true;
                try std.testing.expect(!entry.visible_complete);
                try std.testing.expectEqual(body.visibleSourceEndForRows(expected), entry.visible_source_end);
            }
            try testNativePrefix(&ui, rendered.lines, &drawn);
            testAcknowledgeFullFrame(&ui);
            try std.testing.expectEqual(old_written + expected, ui.records.items[index].stream_written);
            try std.testing.expect(body.base >= old_base);
            try std.testing.expect(!std.mem.eql(u8, ui.notice, "Display commit incomplete; output retained"));
            if (!body.isDrained()) {
                try std.testing.expect(!ui.records.items[index].output);
                try std.testing.expect(body.arena.queryCapacity() > 0);
            }
        }
        try std.testing.expect(saw_preview);
        try std.testing.expect(frames > 1 and frames < 100);
        try std.testing.expect(body.isDrained());
        try std.testing.expectEqual(source.len, body.base);
        try std.testing.expectEqual(rendered.lines.len, drawn);
        try std.testing.expect(ui.records.items[index].output);
        try std.testing.expect(ui.records.items[index].delivery_complete);
        try std.testing.expectEqual(@as(usize, 0), body.arena.queryCapacity());
        try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].lines.len);
        try std.testing.expect(ui.records.items[index].cache == null);
    };
}
test "stream rows publish only after ACK and matching canonical text is not duplicated" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    const stream = ui.records.items[index].stream.?;
    try ui.draw();
    const capacity = stream.arena.queryCapacity();
    const base = stream.base;
    try std.testing.expect(capacity > 0 and stream.pinned and !stream.finished);
    stream.releaseDrainedRender();
    try std.testing.expectEqual(capacity, stream.arena.queryCapacity());
    try std.testing.expectEqual(base, stream.base);
    // The active body keeps no full styled prefix copy; only unwritten rows.
    try std.testing.expect(ui.records.items[index].flow_prefix == null);
    try std.testing.expect(ui.records.items[index].pending_stream_rows != 0);
    try std.testing.expect(!ui.records.items[index].output and !ui.records.items[index].pending_output);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    // Content arriving mid-frame cannot invalidate the delivery in flight.
    try ui.appendDraft(.assistant, "```");
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].stream_written != 0);
    try std.testing.expect(stream.arena.queryCapacity() > 0);
    const unfinished_base = stream.base;
    const unfinished_window = stream.windowBytes();
    const unfinished_capacity = stream.arena.queryCapacity();
    stream.releaseDrainedRender();
    try std.testing.expectEqual(unfinished_capacity, stream.arena.queryCapacity());
    try std.testing.expectEqual(unfinished_base, stream.base);
    try std.testing.expectEqual(unfinished_window, stream.windowBytes());
    const body = try std.testing.allocator.dupe(u8, ui.records.items[index].body.items);
    defer std.testing.allocator.free(body);
    try ui.replaceCommitted(&.{.{ .text = body }}, false, true);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].output);
    try std.testing.expect(ui.records.items[index].flow_prefix == null);
    try std.testing.expectEqual(@as(usize, 35), screen.count("stream-row-"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("Response revised"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-000"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-034"));
}
test "ACKed stream rows are not rewritten by ordinary repaints" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const written = ui.records.items[index].stream_written;
    try std.testing.expect(written != 0);
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(written, ui.records.items[index].stream_written);
    try std.testing.expectEqual(@as(usize, 0), screen.count("Response revised"));
    try std.testing.expect(screen.count("stream-row-000") <= 1);
}
test "width changes re-render only the retained window without duplicate rows" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    const body = ui.records.items[index].stream.?;
    try std.testing.expectEqual(@as(usize, 80), body.columnCount());
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 79), body.columnCount());
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-000"));
    testAcknowledgeFullFrame(&ui);
    const written = ui.records.items[index].stream_written;
    // A width ABA re-analyzes only the retained window; frozen rows are never
    // replayed.
    ui.resize(.{ .columns = 40, .rows = 12 });
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 39), body.columnCount());
    testAcknowledgeFullFrame(&ui);
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 79), body.columnCount());
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].stream_written >= written);
    try std.testing.expect(screen.count("stream-row-000") <= 1);
}
test "new stream text releases each row exactly once" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const old_written = ui.records.items[index].stream_written;
    try ui.appendDraft(.assistant, "stream-row-035 abcdefghijklmnopqrstuvwxyz abcdefghijklmnop\n");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].stream_written > old_written);
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-035"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-000"));
}
test "late ACK commits pinned rows and does not lose mid-frame content" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    try ui.draw();
    const staged = ui.records.items[index].pending_stream_rows;
    try std.testing.expect(staged != 0);
    // Content arrives after staging but before the frame is acknowledged.
    try ui.appendDraft(.assistant, "stream-row-035 abcdefghijklmnopqrstuvwxyz abcdefghijklmnop\n");
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(staged, ui.records.items[index].stream_written);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-035"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-000"));
}
test "withdrawn streamed text is explained without clearing native scrollback" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try ui.replaceCommitted(&.{}, false, true);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(screen.count("stream-row-") > 0);
    try std.testing.expectEqual(@as(usize, 1), screen.count("Stream preview withdrawn"));
}
test "complete canonical retains body beyond large reasoning without synthetic clipping" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.appendDraft(.assistant, "BODY-NOT-YET-ACKED");
    const id = ui.records.items[ui.draft.?].id;
    const thought = try std.testing.allocator.alloc(u8, 70 * 1024);
    defer std.testing.allocator.free(thought);
    @memset(thought, 'r');
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .assistant_committed = &.{ .{ .reasoning = thought }, .{ .text = "BODY-NOT-YET-ACKED" } } }, &cancel);
    var item = bridge.pop().?;
    defer item.deinit();
    try std.testing.expect(!item.display_truncated and item.canonical_complete);
    try std.testing.expectEqualSlices(u8, thought, item.event.assistant_committed[0].reasoning);
    try std.testing.expectEqualStrings("BODY-NOT-YET-ACKED", item.event.assistant_committed[1].text);
    try ui.event(item);
    const index = ui.record_index.get(id).?;
    try std.testing.expectEqualStrings("BODY-NOT-YET-ACKED", ui.records.items[index].body.items);
    try std.testing.expect(!ui.records.items[index].clipped);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 1), screen.count("BODY-NOT-YET-ACKED"));
}
test "complete empty canonical withdraws an unacknowledged streamed body" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.appendDraft(.assistant, "withdraw-me");
    const id = ui.records.items[ui.draft.?].id;
    try ui.replaceCommitted(&.{}, false, true);
    try std.testing.expect(ui.record_index.get(id) == null);
}
test "clipped canonical never replaces a complete displayed stream" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const preview = try std.testing.allocator.dupe(u8, ui.records.items[index].body.items);
    defer std.testing.allocator.free(preview);
    // display_truncated canonical is not a complete body: the long preview and
    // its rows must survive, with an explicit notice instead of a rewrite.
    try ui.replaceCommitted(&.{.{ .text = "cropped final" }}, true, true);
    try std.testing.expect(ui.records.items[index].clipped);
    try std.testing.expectEqualStrings(preview, ui.records.items[index].body.items);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-row-034"));
    try std.testing.expectEqual(@as(usize, 0), screen.count("cropped final"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("truncated for display"));
}
test "native history viewport stays stable during streaming and revisions are explicit" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.user, "stream-goal");
    try seedShiftDraft(&ui);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    // A native viewport is an absolute slice of scrollback+screen, NOT Ui.scroll.
    // Pin an observer eight rows above the current bottom; send no wheel input.
    try std.testing.expect(screen.history_len >= 8);
    const view_top = screen.history_len - 8;
    var pinned: [24]@TypeOf(screen.grid[0]) = undefined;
    for (&pinned, 0..) |*line, index| @memcpy(line, nativeLine(&screen, view_top + index));
    const history = screen.history_len;
    for (35..43) |row_index| {
        var buffer: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&buffer, "stream-row-{d:0>3} abcdefghijklmnopqrstuvwxyz abcdefghijklmnop\n", .{row_index});
        try ui.appendDraft(.assistant, line);
        try ui.draw();
        try std.testing.expect(ui.frame_sparse);
        try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[1M") == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "\n") != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "stream-row-020") == null);
        try screen.replay(ui.frame);
        try std.testing.expect(screen.history_len > history);
        for (&pinned, 0..) |*line_, index| try std.testing.expectEqualSlices(u8, line_, nativeLine(&screen, view_top + index));
        try std.testing.expectEqual(@as(usize, 23), screen.row);
        try std.testing.expect(screen.visible(line[0..14]));
        testAcknowledgeFullFrame(&ui);
    }
    try ui.replaceCommitted(&.{.{ .text = "final-canonical-only" }}, false, true);
    try ui.draw();
    try std.testing.expect(!ui.frame_sparse);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    // Already-visible previews remain identifiable, not silently erased or
    // presented as the corrected canonical answer.
    try std.testing.expect(screen.count("stream-row-") > 0);
    try std.testing.expectEqual(@as(usize, 1), screen.count("Response revised"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("final-canonical-only"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-goal"));
}
test "tail snapshots publish only on full ACK and own bytes after record invalidation" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.appendDraft(.assistant, "stable-body-A");
    try ui.draw();
    try std.testing.expect(ui.tail_snapshot == null and ui.frame_tail_snapshot != null);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(std.mem.find(u8, ui.tail_snapshot.?.rows[0], "stable-body-A") != null);
    // appendDraft invalidates/frees Record.lines; the acknowledged copy stays valid.
    try ui.appendDraft(.assistant, "-extended");
    try std.testing.expect(std.mem.find(u8, ui.tail_snapshot.?.rows[0], "stable-body-A") != null);
    try ui.draw();
    try std.testing.expect(ui.frame_sparse);
    try std.testing.expect(std.mem.find(u8, ui.tail_snapshot.?.rows[0], "extended") == null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(std.mem.find(u8, ui.tail_snapshot.?.rows[0], "extended") != null);
    try ui.draw();
    try std.testing.expect(ui.frame_sparse);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ui.frame, "\x1b[K"));
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("stable-body-A-extended"));
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
}
test "resize defers idle and busy screens during live geometry changes but input may resume early" {
    for ([_]bool{ false, true }) |busy| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.busy = busy;
        _ = try ui.add(.assistant, "stable resize body");
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        for ([_]terminal_module.Size{ .{ .columns = 40, .rows = 24 }, .{ .columns = 40, .rows = 12 }, .{ .columns = 80, .rows = 24 } }) |size| {
            ui.resize(size);
            try std.testing.expect(ui.resize_waiting and !ui.dirty and !ui.drawReady());
            try std.testing.expect(ui.frame.len == 0 and ui.resize_rescue.len == 0);
            try std.testing.expect(ui.tail_snapshot == null and !ui.frame_fresh);
            // Arbitrarily advanced time with only resize reports and animation
            // pulses never produces a frame: no timer, no automatic repair.
            for (0..20) |_| {
                ui.clock_ms += 20;
                ui.resize(size);
                ui.animate();
                try std.testing.expect(!ui.drawReady() and !ui.dirty);
                try std.testing.expect(ui.frame.len == 0 and ui.resize_rescue.len == 0);
            }
        }
        try Ui.key(&ui, .{ .text = .{ .value = "x", .pasted = false } });
        try std.testing.expect(ui.drawReady() and !ui.resize_waiting);
        try std.testing.expectEqualStrings("x", ui.editor.bytes.items);
        try ui.draw();
        try std.testing.expect(ui.frame_fresh and !ui.display_changed);
        testAcknowledgeFullFrame(&ui);
        try std.testing.expect(ui.tail_snapshot != null);
    }
}
test "resize alone never draws and the next real input draws once at the new size" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 80, .rows = 24 };
    try Ui.key(&ui, .{ .text = .{ .value = "visible draft", .pasted = false } });
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const size: terminal_module.Size = .{ .columns = 60, .rows = 12 };
    ui.resize(size);
    // The new dimensions are current, and every old authority/bottom proof is gone.
    try std.testing.expectEqual(size.columns, ui.size.columns);
    try std.testing.expectEqual(size.rows, ui.size.rows);
    try std.testing.expect(ui.resize_waiting and !ui.dirty and !ui.drawReady());
    try std.testing.expect(ui.tail_snapshot == null and !ui.tail_bottom and ui.abandon_tail);
    // No autonomous payload, however far the clock advances.
    for (0..20) |_| {
        ui.clock_ms += 80;
        ui.resize(size);
        ui.animate();
        try std.testing.expect(!ui.drawReady() and !ui.dirty);
        try std.testing.expect(ui.frame.len == 0 and ui.resize_rescue.len == 0);
    }
    // The next real input establishes one fresh bottom-anchored frame at the
    // new width without replaying history.
    try Ui.key(&ui, .{ .text = .{ .value = "!", .pasted = false } });
    try std.testing.expect(ui.drawReady() and !ui.resize_waiting);
    try ui.draw();
    try std.testing.expectEqual(size.columns, ui.frame_size.columns);
    try std.testing.expectEqual(size.rows, ui.frame_size.rows);
    try std.testing.expect(std.mem.find(u8, ui.frame, "visible draft!") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[999B") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[0J") == null);
    try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r"));
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.tail_snapshot != null);
    try std.testing.expectEqualStrings("visible draft!", ui.editor.bytes.items);
}
test "resize revokes approval across ABA and only a complete new frame acknowledges" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.permission = .{ .id = 42, .description = try std.testing.allocator.dupe(u8, "settled resize approval"), .clipped = false };
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    ui.clock_ms = 1000;
    ui.resize(.{ .columns = 60, .rows = 12 });
    ui.clock_ms = 1100;
    const restored: terminal_module.Size = .{ .columns = 80, .rows = 24 };
    ui.resize(restored);
    ui.resize(restored); // A repeated report of the restored size is not an ACK.
    try std.testing.expect(!ui.drawReady() and ui.displayed_permission == null);
    // ABA plus arbitrarily advanced time still cannot revive the authority or
    // produce an autonomous frame.
    ui.clock_ms = 1250;
    ui.resize(restored);
    ui.clock_ms = 4000;
    ui.resize(restored);
    ui.animate();
    try std.testing.expect(!ui.drawReady() and !ui.dirty);
    try std.testing.expect(ui.frame.len == 0 and ui.resize_rescue.len == 0);
    // Only genuine input/content resumes drawing, and the approval still needs a
    // complete fresh frame at the current geometry before Enter may confirm it.
    ui.requestDraw();
    try std.testing.expect(ui.drawReady() and ui.displayed_permission == null);
    try ui.draw();
    try std.testing.expect(ui.frame_permission == 42 and ui.displayed_permission == null);
    // A partial frame interrupted by another resize may publish nothing, but the
    // genuine content it carried keeps its draw obligation: only the old ACK dies.
    ui.frame_offset = 1;
    ui.resize(.{ .columns = 70, .rows = 20 });
    ui.finishFrame();
    try std.testing.expect(ui.displayed_permission == null and !ui.resize_waiting and ui.dirty);
    // Interrupted-write controls must drain first and never acknowledge anything.
    try std.testing.expect(ui.resize_rescue.len != 0 and !ui.drawReady());
    ui.resize_rescue = ""; // Controls-only cleanup cannot publish an ACK.
    // The surviving obligation is ordinary work: no new input, timer or resize is
    // needed to become drawable, and only a complete current-geometry frame ACKs.
    ui.clock_ms += 5000;
    ui.resize(ui.size);
    ui.animate();
    try std.testing.expect(ui.dirty and ui.drawReady() and ui.displayed_permission == null);
    try ui.draw();
    try std.testing.expect(ui.frame_permission == 42 and ui.displayed_permission == null);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(?u64, 42), ui.displayed_permission);
}
test "resize requeues unfinished content but discards animation frames without payload replay" {
    for ([_]bool{ false, true }) |changed| {
        for ([_]usize{ 0, 1 }) |sent| {
            var cancel: p.Cancellation = .{};
            var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
            defer bridge.deinit();
            var ui = fixtureUi(&bridge, &cancel);
            defer ui.deinit();
            ui.busy = true;
            try ui.draw();
            testAcknowledgeFullFrame(&ui);
            ui.clock_ms = 160;
            ui.animate();
            if (changed) {
                const host = bridge.host();
                try host.emit_fn(host.context, .{ .text = "new resize content" }, &cancel);
                var item = bridge.pop().?;
                defer item.deinit();
                try ui.event(item);
            }
            try ui.draw();
            try std.testing.expectEqual(changed, ui.frame_changed);
            ui.frame_offset = sent;
            ui.resize(.{ .columns = 40, .rows = 12 });
            try std.testing.expect(ui.frame.len == 0 and ui.frame_arena == null);
            try std.testing.expect(ui.frame_tail_snapshot == null and ui.tail_snapshot == null);
            try std.testing.expectEqual(!changed, ui.resize_waiting);
            try std.testing.expectEqualStrings(if (sent == 0) "" else "\x18\x1b[0m" ++ terminal_module.sync_end ++ "\x1b[?25h", ui.resize_rescue);
            try std.testing.expect(std.mem.indexOfAny(u8, ui.resize_rescue, "\r\n") == null);
            ui.finishFrame();
            try std.testing.expect(!ui.frame_fresh and ui.tail_snapshot == null);
            ui.resize_rescue = ""; // Controls-only flush is not a display ACK.
            if (!changed) {
                // A pure animation pulse is not resurrected by an advanced clock.
                for (0..20) |_| {
                    ui.clock_ms += 80;
                    ui.resize(.{ .columns = 40, .rows = 12 });
                    ui.animate();
                    try std.testing.expect(!ui.drawReady());
                }
            }
            try std.testing.expectEqual(changed, ui.drawReady());
            if (changed) {
                try ui.draw();
                try std.testing.expect(std.mem.indexOf(u8, ui.frame, "new resize content") != null);
                // A real update establishes a bounded new bottom anchor.
                try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[999B") == null);
                try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r\x1b[12B"));
                testAcknowledgeFullFrame(&ui);
            }
        }
    }
}
test "resize preserves real input updates not yet staged" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .{ .text = .{ .value = "pending draft", .pasted = false } });
    ui.resize(.{ .columns = 40, .rows = 24 });
    try std.testing.expect(ui.drawReady() and !ui.resize_waiting);
    try std.testing.expectEqualStrings("pending draft", ui.editor.bytes.items);
}
test "resize invalidates acknowledged approval until fresh input and frame" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.permission = .{ .id = 42, .description = try std.testing.allocator.dupe(u8, "safe resize approval"), .clipped = false };
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(?u64, 42), ui.displayed_permission);
    ui.resize(.{ .columns = 70, .rows = 20 });
    try std.testing.expect(ui.resize_waiting and ui.displayed_permission == null and !ui.dirty);
    try Ui.key(&ui, .enter);
    try std.testing.expect(ui.permission != null and ui.displayed_permission == null and ui.drawReady());
    try ui.draw();
    try std.testing.expect(ui.displayed_permission == null);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(?u64, 42), ui.displayed_permission);
}
test "resize at every sparse frame byte drops stale relative edits and cannot republish ownership" {
    for ([_]bool{ false, true }) |shifted| {
        var length: usize = 1;
        var offset: usize = 0;
        while (offset < length) : (offset += 1) {
            var cancel: p.Cancellation = .{};
            var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
            defer bridge.deinit();
            var ui = fixtureUi(&bridge, &cancel);
            defer ui.deinit();
            // Keep this byte-split fixture ASCII: Screen models CSI cancellation,
            // not a terminal's replacement-character policy for truncated UTF-8.
            if (shifted) try seedShiftDraft(&ui) else try ui.appendDraft(.assistant, "owned body");
            try ui.draw();
            testAcknowledgeFullFrame(&ui);
            try ui.appendDraft(.assistant, if (shifted) "stream-row-035 abcdefghijklmnopqrstuvwxyz abcdefghijklmnop\n" else " extended");
            try ui.draw();
            try std.testing.expect(ui.frame_sparse);
            const old_prefix = if (ui.draft) |index| if (ui.records.items[index].flow_prefix) |prefix| prefix.rowCount() else 0 else 0;
            if (shifted) {
                try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[1M") == null);
                try std.testing.expect(std.mem.find(u8, ui.frame, "\n") != null);
            }
            for (ui.frame) |byte| try std.testing.expect(byte < 128);
            length = ui.frame.len;
            var captured: Io.Writer.Allocating = .init(std.testing.allocator);
            defer captured.deinit();
            try captured.writer.writeAll(ui.frame[0..offset]);
            ui.frame_offset = offset;
            ui.resize(.{ .columns = 40, .rows = 12 });
            try std.testing.expect(!ui.frame_sparse and !ui.frame_fresh);
            try std.testing.expect(ui.tail_snapshot == null);
            try std.testing.expectEqual(@as(usize, 0), ui.frame_offset);
            try std.testing.expect(ui.frame.len == 0 and ui.frame_arena == null);
            try std.testing.expectEqualStrings(if (offset == 0) "" else "\x18\x1b[0m" ++ terminal_module.sync_end ++ "\x1b[?25h", ui.resize_rescue);
            try std.testing.expect(std.mem.indexOfAny(u8, ui.resize_rescue, "\r\n") == null);
            try captured.writer.writeAll(ui.resize_rescue);
            var screen: @import("../tests/regular_screen.zig").Screen = .{};
            // Syntax/escape cancellation only, not a physical resize/reflow oracle.
            try screen.replay(captured.written());
            if (offset != 0) try std.testing.expect(std.mem.endsWith(u8, captured.written(), terminal_module.sync_end ++ "\x1b[?25h"));
            // Even returning to old dimensions does not revive the old ACK/cache.
            ui.resize(.{ .columns = 80, .rows = 24 });
            ui.finishFrame(); // No old-width payload survives to acknowledge.
            try std.testing.expect(ui.tail_snapshot == null);
            try std.testing.expect(ui.displayed_permission == null and ui.displayed_model_epoch == null);
            if (ui.draft) |index| {
                const record = &ui.records.items[index];
                try std.testing.expectEqual(old_prefix, if (record.flow_prefix) |prefix| prefix.rowCount() else 0);
                try std.testing.expect(record.pending_flow_prefix == null);
            }
            try std.testing.expect(ui.abandon_tail);
        }
    }
}
test "tail snapshot construction and resize release all allocations under OOM" {
    try text.initLocale();
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    for ([_]bool{ false, true }) |native| try std.testing.checkAllAllocationFailures(backing.allocator(), tailAllocationScenario, .{native});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}
test "reasoning tail allocation failures release every owned tail and record" {
    try text.initLocale();
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), reasoningTailAllocationScenario, .{});
    try std.testing.expectEqual(backing.allocated_bytes, backing.freed_bytes);
}
test "composer displays startup zero and latest actual usage or unknown without billing accumulation" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.display.seed(.{ .tokens = 0, .limit = 1000000 });
    const green_prompt = "(" ++ theme.reset ++ "\x1b[1mfixture" ++ theme.reset ++ "\x1b[1m) " ++ theme.success;
    const prompt_end = theme.reset ++ "\x1b[1m>" ++ theme.reset ++ " ";
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, green_prompt ++ "0.0%" ++ prompt_end) != null);
    testAcknowledgeFullFrame(&ui);
    const Case = struct { purpose: p.Purpose, usage: p.Usage, prefix: []const u8 };
    const host = bridge.host();
    for ([_]Case{
        .{ .purpose = .normal, .usage = .{ .input_tokens = 12000, .output_tokens = 1000, .cached_input_tokens = 10000, .reasoning_tokens = 300 }, .prefix = green_prompt ++ "1.3%" ++ prompt_end },
        .{ .purpose = .summary, .usage = .{ .total_tokens = 1000 }, .prefix = green_prompt ++ "0.1%" ++ prompt_end },
        .{ .purpose = .normal, .usage = .{ .input_tokens = 12 }, .prefix = "\x1b[1m(fixture) ?%>" ++ theme.reset ++ " " },
        .{ .purpose = .normal, .usage = .{ .total_tokens = 0 }, .prefix = green_prompt ++ "0.0%" ++ prompt_end },
    }) |case| {
        try host.emit_fn(host.context, .{ .usage = .{ .purpose = case.purpose, .protocol = .chat, .value = case.usage } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, case.prefix) != null);
        testAcknowledgeFullFrame(&ui);
    }
}
test "terminal details publish once in conversation and never own the footer" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    ui.notice = "Ready";
    const result: r.Terminal = .{ .status = .paused, .detail = error.OutputLimitReached, .model_failure = .output_limit };
    ui.last_terminal = result;
    ui.notice = Ui.terminalNotice(result);
    ui.queueTerminalNotice(result);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    const record = ui.records.items[0];
    try std.testing.expectEqual(NoticeLevel.failure, record.notice_level);
    try std.testing.expect(std.mem.find(u8, record.body.items, "OutputLimitReached") != null);
    try std.testing.expect(std.mem.find(u8, record.body.items, "limits.max_output_tokens") == null);
    const hint = try ui.hint(arena.allocator(), ui.connection.current());
    try std.testing.expect(std.mem.find(u8, hint, "OutputLimitReached") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, hint, '\x1b') == null);
}
test "input and decision policy pauses stay red in conversation and out of the footer" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    ui.notice = "Ready";
    for ([_]anyerror{ error.InputBudgetExceeded, error.UnknownInputPriceThreshold, error.InputBudgetSummaryFailed, error.DecisionUnavailable }) |detail| {
        try std.testing.expect(r.policyPause(detail));
        const result: r.Terminal = .{ .status = .paused, .detail = detail };
        ui.last_terminal = result;
        ui.notice = Ui.terminalNotice(result);
        ui.queueTerminalNotice(result);
        const record = ui.records.items[ui.records.items.len - 1];
        try std.testing.expectEqual(NoticeLevel.failure, record.notice_level);
        try std.testing.expect(std.mem.find(u8, record.body.items, if (detail == error.DecisionUnavailable) "decision review failed" else @errorName(detail)) != null);
        const hint = try ui.hint(arena.allocator(), ui.connection.current());
        try std.testing.expect(std.mem.find(u8, hint, "round limit") == null);
        try std.testing.expect(std.mem.find(u8, hint, "HTTP") == null);
        ui.removeRecord(ui.records.items.len - 1);
    }
}
test "neutral footer keeps queue and capability pending but not terminal or storage faults" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = ui.connection.current();
    state.settings_notice = "Saved thinking level not applied: model capabilities unknown";
    state.pending_default_effort = .medium;
    ui.notice = "Ready";
    // The deliberate policy pause is conversation detail only.
    var result: r.Terminal = .{ .status = .paused, .detail = error.DecisionUnavailable };
    ui.last_terminal = result;
    ui.notice = Ui.terminalNotice(result);
    ui.queueTerminalNotice(result);
    const expected = "Default thinking: medium; awaiting model capabilities | Saved thinking level not applied: model capabilities unknown";
    try std.testing.expectEqualStrings(expected, try ui.footerHint(arena.allocator(), state));
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "decision review failed") != null);
    testAcknowledgeFullFrame(&ui);
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "retained queued input");
    ui.inbox.pause();
    try std.testing.expect(ui.remote() == null);
    try std.testing.expectEqual(@as(usize, 1), ui.queueSnapshot().follow_up);
    try std.testing.expect(ui.queueSnapshot().paused);
    states: {
        var queued_state = state;
        queued_state.settings_notice = null;
        queued_state.pending_default_effort = null;
        const queued = try ui.footerHint(arena.allocator(), queued_state);
        try std.testing.expect(std.mem.find(u8, queued, "S:0 F:1 paused (/queue resume)") != null);
        try std.testing.expect(std.mem.find(u8, queued, "decision review failed") == null);
        break :states;
    }
    // Storage faults are migrated by observeAdvisories, not aggregated here.
    state.settings_error = error.TestSettingsFailure;
    state.log_error = error.TestLogFailure;
    const storage = try ui.footerHint(arena.allocator(), state);
    try std.testing.expect(std.mem.find(u8, storage, "SETTINGS FAILED") == null);
    try std.testing.expect(std.mem.find(u8, storage, "REC FAILED") == null);
    // Explicit cancellation stays plain and is never a footer terminal.
    result = .{ .status = .canceled, .detail = error.Canceled };
    ui.last_terminal = result;
    ui.notice = Ui.terminalNotice(result);
    ui.queueTerminalNotice(result);
    const canceled = ui.records.items[ui.records.items.len - 1];
    try std.testing.expectEqual(NoticeLevel.plain, canceled.notice_level);
    try std.testing.expectEqualStrings("Canceled; prior side effects remain", canceled.body.items);
    try std.testing.expect(std.mem.find(u8, try ui.hint(arena.allocator(), state), "Canceled") == null);
}
test "capability pending hint deduplicates only the matching saved warning" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = ui.connection.current();
    state.settings_notice = "Saved thinking level not applied: model capabilities unknown";
    for ([_][]const u8{
        "Thinking capabilities are loading; try Shift+Tab again shortly",
        "Thinking capabilities unknown: refresh /model or declare reasoning levels in configuration",
    }) |notice| {
        ui.notice = notice;
        try std.testing.expectEqualStrings(notice, try ui.hint(arena.allocator(), state));
        // Storage faults are no longer aggregated into the same footer line.
        state.settings_error = error.TestSettingsFailure;
        try std.testing.expectEqualStrings(notice, try ui.hint(arena.allocator(), state));
        state.settings_error = null;
    }
    ui.notice = "Could not save thinking option; previous option kept";
    const unrelated = try ui.hint(arena.allocator(), state);
    try std.testing.expect(std.mem.find(u8, unrelated, ui.notice) == null);
    try std.testing.expect(std.mem.find(u8, unrelated, state.settings_notice.?) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, unrelated, '\x1b') == null);
}
test "menu restored view falls back to one canonical footer success notice" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{ .settings_notice = session_client.restored_notice };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    // An async/menu restored view never replays history, so no transcript
    // banner exists and the canonical footer notice is the single success.
    try std.testing.expect(!ui.history_notice_shown);
    ui.notice = session_client.restored_notice;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), ui.connection.current()));
    ui.observeAdvisories();
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(NoticeLevel.plain, ui.records.items[0].notice_level);
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ui.frame, session_client.restored_notice));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ui.frame, "prior tools are NOT rerun"));
    testAcknowledgeFullFrame(&ui);
}
test "restored banner keeps unrelated action and storage failures visible" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{ .settings_notice = session_client.restored_notice };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    try replayMessages(&ui, std.testing.allocator, &.{.{ .role = .user, .blocks = &.{.{ .text = "retained question" }} }});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = ui.connection.current();
    // An unrelated action success keeps its own notice; only the canonical
    // restored twin is dropped.
    ui.notice = "Could not save thinking option; previous option kept";
    const action = try ui.hint(arena.allocator(), state);
    try std.testing.expectEqualStrings("", action);
    try std.testing.expect(std.mem.find(u8, action, session_client.restored_notice) == null);
    // Unrelated capability warnings still appear next to the banner.
    state.settings_notice = "Saved thinking level not applied: model capabilities unknown";
    ui.notice = "Ready";
    const capability = try ui.hint(arena.allocator(), state);
    try std.testing.expectEqualStrings(state.settings_notice.?, capability);
    // Real storage failures are never hidden by the restored state.
    state.settings_error = error.TestSettingsFailure;
    state.log_error = error.TestLogFailure;
    const storage = try ui.hint(arena.allocator(), state);
    try std.testing.expect(std.mem.find(u8, storage, "SETTINGS FAILED: TestSettingsFailure") == null);
    try std.testing.expect(std.mem.find(u8, storage, "REC FAILED: TestLogFailure") == null);
    try std.testing.expect(std.mem.find(u8, storage, session_client.restored_notice) == null);
}
test "selection restore success is plain and published once" {
    const message = "Selection restored; NEW EMPTY CHAT (history not restored)";
    const Fake = struct {
        fn current(_: *anyopaque) Connection.State {
            return .{ .runtime = null, .available = true, .model = "fixture", .base_url = "", .settings_notice = message };
        }
    };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.current_fn = Fake.current;
    try std.testing.expectEqual(NoticeLevel.plain, Ui.oneShotNoticeLevel(message));
    ui.observeAdvisories();
    ui.observeAdvisories();
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(NoticeLevel.plain, ui.records.items[0].notice_level);
    try std.testing.expectEqualStrings(message, ui.records.items[0].body.items);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(std.mem.find(u8, try ui.hint(arena.allocator(), ui.connection.current()), message) == null);
    try std.testing.expect(!ui.history_notice_shown);
}
test "per-view reset releases restored ownership for the next view" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 1 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try replayMessages(&ui, std.testing.allocator, &.{.{ .role = .user, .blocks = &.{.{ .text = "retained question" }} }});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = ui.connection.current();
    state.settings_notice = session_client.restored_notice;
    ui.notice = session_client.restored_notice;
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), state));
    // The next view starts without that banner, so one canonical footer
    // notice is correct again.
    fake.snapshot.control_epoch = 2;
    try ui.resetSessionView(&fake.snapshot);
    try std.testing.expect(!ui.history_notice_shown);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    ui.notice = session_client.restored_notice;
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), state));
    ui.observeAdvisories();
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(NoticeLevel.plain, ui.records.items[0].notice_level);
    try std.testing.expectEqual(@as(u64, 2), ui.remote_epoch);
}
test "evicted restored banner never resurrects a stale footer success" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{ .settings_notice = session_client.restored_notice };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    try replayMessages(&ui, std.testing.allocator, &.{.{ .role = .user, .blocks = &.{.{ .text = "retained question" }} }});
    ui.notice = session_client.restored_notice;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), ui.connection.current()));
    // Unrelated updates keep working without turning the suppressed success
    // into a lingering or reappearing footer notice.
    ui.notice = "Could not save thinking option; previous option kept";
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), ui.connection.current()));
    ui.notice = session_client.restored_notice;
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), ui.connection.current()));
    // Drop the banner row itself: suppression is owned by the view, never
    // re-derived by scanning records, so no stale success is fabricated.
    ui.removeRecord(0);
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), ui.connection.current()));
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ui.frame, session_client.restored_notice));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ui.frame, "prior tools are NOT rerun"));
    testAcknowledgeFullFrame(&ui);
}
test "read command errors include a safe reason after error and never display raw results" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const call = try shared.tools.Call.init(std.testing.allocator, "read_file", "{\"path\":\"README.md\"}");
    defer call.deinit(std.testing.allocator);
    const caption = try presentation.fromCall(std.testing.allocator, call);
    defer caption.deinit(std.testing.allocator);
    try ui.toolCompleted(caption, .{ .text = "FileNotFound", .is_error = true, .duration_ms = 3 });
    try std.testing.expectEqualStrings("r README.md [error] FileNotFound: file not found", ui.records.items[0].body.items);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "[error] FileNotFound: file not found") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "3ms") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.toolCompleted(caption, .{ .text = "{\"private-result\":\"secret\"}\n\x1b[2J", .is_error = true });
    try std.testing.expect(std.mem.find(u8, ui.records.items[1].body.items, "[error] Read failed: details unavailable") != null);
    try std.testing.expect(std.mem.find(u8, ui.records.items[1].body.items, "secret") == null);
    try ui.toolCompleted(caption, .{ .text = "FileNotFound", .is_error = true, .canceled = true });
    try std.testing.expectEqualStrings("r README.md [canceled]", ui.records.items[2].body.items);
}
test "sequential tool records from different frames have no gaps then final prose has one gap" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    for ([_][]const u8{ "one.txt", "two.txt", "three.txt" }) |path| {
        const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{path});
        defer std.testing.allocator.free(args);
        const call = try shared.tools.Call.init(std.testing.allocator, "read_file", args);
        defer call.deinit(std.testing.allocator);
        const caption = try presentation.fromCall(std.testing.allocator, call);
        defer caption.deinit(std.testing.allocator);
        try ui.toolCompleted(caption, .{ .text = "hidden-result", .file_stats = .{ .read = 1 } });
        try ui.draw();
        try screen.replay(ui.frame);
        try std.testing.expectEqual(@as(usize, 1), screen.count(path));
        try std.testing.expect(screen.visible(path));
        try std.testing.expectEqual(screen.rows - 1, screen.row);
        testAcknowledgeFullFrame(&ui);
    }
    try ui.replaceCommitted(&.{.{ .text = "answer-without-heading" }}, false, true);
    try ui.draw();
    try screen.replay(ui.frame);
    const first = for (screen.grid, 0..) |line, row| {
        if (std.mem.find(u8, &line, "one.txt") != null) break row;
    } else return error.MissingRowPrefix;
    try std.testing.expect(std.mem.find(u8, &screen.grid[first + 1], "two.txt") != null);
    try std.testing.expect(std.mem.find(u8, &screen.grid[first + 2], "three.txt") != null);
    try expectTranscriptGap(&screen, "three.txt", "answer-without-heading");
    try std.testing.expectEqual(@as(usize, 0), screen.count("Final answer"));
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 1), screen.count("answer-without-heading"));
    for ([_][]const u8{ "one.txt", "two.txt", "three.txt" }) |path| try std.testing.expectEqual(@as(usize, 1), screen.count(path));
    testAcknowledgeFullFrame(&ui);
}
test "configured effort colors idle prefix before reasoning but never the busy marker" {
    const Owner = struct {
        effort: shared.ReasoningEffort,
        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            var state = FixtureConnection.current(raw);
            state.reasoning_effort = self.effort;
            return state;
        }
    };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var owner: Owner = .{ .effort = .high };
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = .{ .context = &owner, .current_fn = Owner.current, .configure_fn = FixtureConnection.configure };
    _ = try ui.editor.insert("input-default");
    // Idle startup, without any delta or mutable Runtime reads.
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "(" ++ (comptime theme.effortColor(.high)) ++ "fixture" ++ theme.reset ++ "\x1b[1m) " ++ theme.reset ++ "\x1b[1m?%" ++ theme.reset ++ "\x1b[1m>" ++ theme.reset ++ " input-default") != null);
    testAcknowledgeFullFrame(&ui);
    ui.mode = .calling_model;
    ui.display.reset();
    ui.display.observe(.{ .state = .calling_model }, 0);
    for ([_]u64{ 1100, 3100, 9100 }) |now| {
        ui.clock_ms = now;
        try ui.draw();
        const marker = try std.fmt.allocPrint(std.testing.allocator, "{s}\x1b[1m{s}{s}{s} input-default", .{ theme.reset, theme.command_pulse[shared.activity.commandStep(now)], activity.spinner(now), theme.reset });
        defer std.testing.allocator.free(marker);
        try std.testing.expect(std.mem.find(u8, ui.frame, marker) != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, theme.effortColor(.high)) == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, theme.model_flow[ui.model_flow.step()]) != null);
        testAcknowledgeFullFrame(&ui);
    }
    ui.display.observe(.{ .reasoning = "late thought" }, 9100);
    ui.display.finish(.{ .status = .success });
    ui.mode = null;
    owner.effort = .low;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "(" ++ (comptime theme.effortColor(.low)) ++ "fixture" ++ theme.reset ++ "\x1b[1m) " ++ theme.reset ++ "\x1b[1m?%" ++ theme.reset ++ "\x1b[1m>" ++ theme.reset ++ " input-default") != null);
    testAcknowledgeFullFrame(&ui);
    owner.effort = .unspecified;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[1m(fixture) ?%>" ++ theme.reset ++ " input-default") != null);
    testAcknowledgeFullFrame(&ui);
}
test "composer frame keeps context occupancy colors static while model and spinner animate" {
    for ([_]bool{ false, true }) |busy| {
        for ([_]u64{ 0, 25, 50 }) |tokens| {
            var cancel: p.Cancellation = .{};
            var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
            defer bridge.deinit();
            var ui = fixtureUi(&bridge, &cancel);
            defer ui.deinit();
            ui.display.observe(.{ .context_snapshot = .{ .tokens = tokens, .limit = 100 } }, 0);
            if (busy) ui.mode = .calling_model;
            ui.clock_ms = 80;
            _ = try ui.editor.insert("default-input");
            try ui.draw();
            const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}{d}.0%{s}\x1b[1m{s}{s}{s} default-input", .{ if (tokens == 0) theme.success else if (tokens == 25) "\x1b[38;5;220m" else theme.failure, tokens, theme.reset, if (busy) theme.command_pulse[0] else "", if (busy) activity.spinner(80) else ">", theme.reset });
            defer std.testing.allocator.free(expected);
            try std.testing.expect(std.mem.find(u8, ui.frame, expected) != null);
            testAcknowledgeFullFrame(&ui);
        }
    }
}
test "pending restored history stays visible with an unmatched tool result and unavailable service" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{ .settings_notice = "Saved thinking level not applied: model capabilities unknown" };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    try replayMessages(&ui, std.testing.allocator, &.{
        .{ .role = .user, .blocks = &.{.{ .text = "retained question" }} },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{ .call_id = "absent-call", .text = "retained result" } }} },
        .{ .role = .assistant, .blocks = &.{.{ .text = "retained answer" }} },
    });
    const count = ui.records.items.len;
    try std.testing.expect(count >= 3);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(fixture.settings_notice.?, try ui.hint(arena.allocator(), ui.connection.current()));
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("new question\r", sink);
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqual(count + 1, ui.records.items.len);
    try std.testing.expectEqual(NoticeLevel.failure, ui.records.items[count].notice_level);
    try std.testing.expect(ui.future == null and !ui.busy and ui.prompt == null);
    try std.testing.expectEqualStrings("retained answer", ui.records.items[count - 1].body.items);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("retained question", ui.input_history.entries.items[0]);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "retained answer") != null);
}
test "composer reflects owner low price policy without reading runtime configuration" {
    try text.initLocale();
    for ([_]bool{ false, true }) |enabled| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var fixture = SelectionFixture{ .low_price_input = enabled };
        defer fixture.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.connection = fixture.connection();
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed("typed", sink);
        try ui.draw();
        const prefix = if (enabled) theme.success ++ "L3.1%" ++ theme.reset else theme.success ++ "3.1%" ++ theme.reset;
        try std.testing.expect(std.mem.find(u8, ui.frame, prefix) != null);
        try std.testing.expectEqual(enabled, std.mem.find(u8, ui.frame, "L3.1%") != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "L ") == null);
        try std.testing.expectEqualStrings("typed", ui.editor.bytes.items);
        try std.testing.expectEqual(@as(usize, 5), ui.editor.cursor);
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try screen.replay(ui.frame);
        try std.testing.expect(std.mem.find(u8, &screen.grid[screen.row], if (enabled) ") L3.1%> typed" else ") 3.1%> typed") != null);
    }
}
test "model only default color prompt has no headers cache or status and preserves cursor" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    _ = try ui.editor.insert("hello\t你");
    try ui.appendDraft(.reasoning, "unprefixed-thought");
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Thinking") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "thin |") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "tools trusted") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, ".thin/sessions") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[1m(fixture) ?%>" ++ theme.reset ++ " hello    你") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "90.0%") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "(fixture)") == null);
    const decoration = "(fixture) ?%> ";
    const position = try std.fmt.allocPrint(std.testing.allocator, "\r\x1b[{d}C" ++ terminal_module.sync_end ++ "\x1b[?25h", .{text.width(decoration) + text.width("hello    你")});
    defer std.testing.allocator.free(position);
    try std.testing.expect(std.mem.endsWith(u8, ui.frame, position));
    try std.testing.expectEqualStrings("hello\t你", ui.editor.bytes.items);
    testAcknowledgeFullFrame(&ui);
}
test "single composer hides statistics and completion and uses flow and exact braille spinner" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.mode = .calling_model;
    ui.display.meter.reset();
    ui.display.meter.beginCall();
    ui.display.meter.observe(100, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    ui.model_flow.advance(0, true, null);
    ui.clock_ms = 600;
    try ui.appendDraft(.assistant, "visible-body");
    _ = try ui.editor.insert("typed-default-color");
    try ui.draw();
    for ([_][]const u8{ "TPS:", "TTFT:", "tokens in:", "summary in:", "cost:", "loading", "Completed", "calling_model" }) |removed| try std.testing.expect(std.mem.find(u8, ui.frame, removed) == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.reset ++ "\x1b[1m" ++ theme.command_pulse[5] ++ "⠧" ++ theme.reset ++ " typed-default-color") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.model_flow[ui.model_flow.step()]) != null);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("visible-body"));
    // The status is immediately above the composer, with a separator before it.
    const warning = "Not configured: /login, then /model";
    try std.testing.expectEqualStrings(warning, std.mem.trimEnd(u8, &screen.grid[screen.rows - 2], " "));
    var warning_count: usize = 0;
    for (screen.grid[0..screen.rows]) |row| warning_count += std.mem.count(u8, &row, warning);
    try std.testing.expectEqual(@as(usize, 1), warning_count);
    for (screen.grid[screen.rows - 3]) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
    try std.testing.expect(std.mem.find(u8, &screen.grid[screen.rows - 1], "(fixture) ?%~ typed-default-color") != null);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
    ui.clock_ms = 680;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.command_pulse[5] ++ "⠇" ++ theme.reset ++ " typed-default-color") != null);
    testAcknowledgeFullFrame(&ui);
    ui.mode = null;
    ui.draft = null;
    ui.notice = "Completed"; // Even old application success notices cannot add a row.
    ui.last_terminal = .{ .status = .success, .usage = .{ .normal_calls = 1, .normal = .{ .input_tokens = 10562, .output_tokens = 873, .cached_input_tokens = 9600 } } };
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[1m(fixture) ?%>" ++ theme.reset ++ " typed-default-color") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Completed") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "tokens in:") == null);
    testAcknowledgeFullFrame(&ui);
}
test "flow model prefix wraps long editor suffix without changing raw cursor bytes" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const raw: [200]u8 = @splat('x');
    _ = try ui.editor.insert(&raw);
    ui.editor.cursor = 1;
    ui.mode = .calling_model;
    ui.clock_ms = 80;
    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    const first_composer = try ui.prepareComposer(first_arena.allocator(), ui.connection.current(), ui.size.columns -| 1);
    try ui.draw();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    // The cursor is on the first wrapped composer row, not the frame's last row.
    try std.testing.expectEqual(screen.rows - 1 - ui.frame_cursor_rows_up, screen.row);
    const first_row = screen.row - first_composer.layout.cursor_row;
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[first_row], "(fixture) ?%~ x"));
    try std.testing.expectEqual(text.width(first_composer.decoration.plain) + first_composer.layout.cursor_column, screen.col);
    // With no body above it, the composer is preceded only by the fixture's real
    // notice: no reserved blank row and no second composer.
    if (first_row > 0) {
        try std.testing.expect(std.mem.find(u8, &screen.grid[first_row - 1], "Not configured") != null);
        try std.testing.expect(std.mem.find(u8, &screen.grid[first_row - 1], "?%>") == null);
    }
    try std.testing.expectEqualStrings(&raw, ui.editor.bytes.items);
    testAcknowledgeFullFrame(&ui);
    ui.editor.cursor = raw.len;
    var last_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer last_arena.deinit();
    const last_composer = try ui.prepareComposer(last_arena.allocator(), ui.connection.current(), ui.size.columns -| 1);
    try ui.draw();
    try screen.replay(ui.frame);
    // The composer is the frame's last block: its final row is the frame row.
    try std.testing.expectEqual(screen.rows - 1 - (last_composer.layout.lines.len - 1 - last_composer.layout.cursor_row), screen.row);
    try std.testing.expectEqual(text.width(last_composer.decoration.plain) + last_composer.layout.cursor_column, screen.col);
    try std.testing.expectEqualStrings(&raw, ui.editor.bytes.items);
    testAcknowledgeFullFrame(&ui);
}
test "resize abandons unknown rows and old completed approval cannot authorize" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.permission = .{ .id = 42, .description = try std.testing.allocator.dupe(u8, "safe preview"), .clipped = false };
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(?u64, 42), ui.displayed_permission);
    try ui.draw();
    try std.testing.expect(ui.displayed_permission == null);
    ui.frame_offset = 1; // Even a partially written reclaim escape is unsafe after reflow.
    ui.resize(.{ .columns = 70, .rows = 20 });
    try std.testing.expect(ui.frame.len == 0 and ui.frame_offset == 0);
    try std.testing.expectEqualStrings("\x18\x1b[0m" ++ terminal_module.sync_end ++ "\x1b[?25h", ui.resize_rescue);
    ui.resize(.{ .columns = 80, .rows = 24 });
    ui.finishFrame();
    try std.testing.expect(ui.displayed_permission == null);
    // ABA down to the repeated size report cannot schedule an autonomous frame.
    ui.clock_ms += 5000;
    ui.resize(.{ .columns = 80, .rows = 24 });
    ui.animate();
    try std.testing.expect(!ui.drawReady() and ui.frame.len == 0);
    ui.requestDraw(); // Genuine update, not a timer or a geometry repair.
    try ui.draw();
    try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r\x1b[24B"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[999B") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[6A") == null);
    // The compact confirmation occupies preview, unconfigured hint and question.
    try std.testing.expectEqual(@as(usize, 3), ui.frame_height);
    try std.testing.expect(ui.displayed_permission == null);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(?u64, 42), ui.displayed_permission);
}
test "exit blank cleanup drains and restores completed transcript on owned PTY" {
    const abi = @import("../platform/terminal_abi.zig");
    var master: c_int = undefined;
    var slave: c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), abi.openpty(&master, &slave, null, null, null));
    defer _ = std.c.close(master);
    defer _ = std.c.close(slave);
    const master_flags = std.c.fcntl(master, std.c.F.GETFL);
    try std.testing.expect(master_flags >= 0);
    try std.testing.expect(std.c.fcntl(master, std.c.F.SETFL, master_flags | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true }))) >= 0);
    _ = std.c.write(slave, "prior-shell-output\r\n", 20);
    var terminal = try terminal_module.Terminal.fromFd(slave, false);
    defer terminal.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.terminal = &terminal;
    ui.connection.current_fn = FixtureConnection.configuredCurrent;
    try ui.draw(); // A pending frame when Ctrl+D arrives.
    _ = try ui.add(.assistant, "final-exit-reply");
    ui.notice = "pty-footer";
    ui.observeAdvisories();
    try ui.parser.feed("\x04", .{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expect(ui.ctrl_d_exit and ui.exitAuthorized());
    try ui.drainExit();
    try std.testing.expect(ui.frame.len == 0 and !ui.dirty);
    try std.testing.expect(ui.records.items[0].output);
    var buffer: [16384]u8 = undefined;
    var used: usize = 0;
    const Capture = struct {
        fn readAvailable(fd: c_int, bytes: []u8, count: *usize) void {
            while (count.* < bytes.len) {
                const n = std.c.read(fd, bytes[count.*..].ptr, bytes.len - count.*);
                if (n <= 0) break;
                count.* += @intCast(n);
            }
        }
    };
    Capture.readAvailable(master, &buffer, &used);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(buffer[0..used]);
    const history = try std.testing.allocator.dupe(@TypeOf(screen.history[0]), screen.history[0..screen.history_len]);
    defer std.testing.allocator.free(history);
    const before_cleanup = used;
    ui.tidyIdleExit();
    Capture.readAvailable(master, &buffer, &used);
    try std.testing.expect(used > before_cleanup);
    try screen.replay(buffer[before_cleanup..used]);
    try std.testing.expectEqualSlices(@TypeOf(screen.history[0]), history, screen.history[0..screen.history_len]);
    var last_content: ?usize = null;
    for (screen.grid[0..screen.rows], 0..) |line, index| {
        if (std.mem.indexOf(u8, &line, "pty-footer") != null) last_content = index;
    }
    try std.testing.expect(last_content != null);
    try std.testing.expectEqual(last_content.?, screen.row);
    const before_restore = used;
    try std.testing.expect(terminal.restore());
    Capture.readAvailable(master, &buffer, &used);
    try screen.replay(buffer[before_restore..used]);
    try screen.replay("pty-shell-next");
    try std.testing.expectEqual(last_content.? + 1, screen.row);
    try std.testing.expect(screen.row < 8);
    for ([_][]const u8{ "prior-shell-output", "final-exit-reply", "pty-footer", "pty-shell-next" }) |marker|
        try std.testing.expectEqual(@as(usize, 1), screen.count(marker));
    try std.testing.expectEqualSlices(@TypeOf(screen.history[0]), history, screen.history[0..screen.history_len]);
    const output = buffer[0..used];
    try std.testing.expect(std.mem.find(u8, output, "prior-shell-output") != null);
    try std.testing.expect(std.mem.find(u8, output, "final-exit-reply") != null);
    try @import("../tests/regular_screen.zig").rejectFullscreen(output);
    for ([_][]const u8{ "1049", "1047", "\x1b[H", "\x1b[2J" }) |forbidden|
        try std.testing.expect(std.mem.find(u8, output, forbidden) == null);
}
test "application log failure remains visible without poisoning runtime" {
    const ConnectionFixture = struct {
        runtime: r.Runtime = undefined, // 仅借用地址供 ready 状态判断，本测试不调用它。
        failed: bool,

        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{
                .runtime = &self.runtime,
                .model = "fixture",
                .base_url = "http://unused.invalid",
                .log_error = if (self.failed) error.NoSpaceLeft else null,
            };
        }
    };
    for ([_]bool{ false, true }) |failed| {
        var cancel = p.Cancellation{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var connection = ConnectionFixture{ .failed = failed };
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.connection.context = &connection;
        ui.connection.current_fn = ConnectionFixture.current;
        ui.observeAdvisories();
        try ui.draw();
        if (failed) try std.testing.expect(std.mem.find(u8, ui.frame, "REC FAILED: NoSpaceLeft") != null) else try std.testing.expect(std.mem.find(u8, ui.frame, "REC FAILED") == null);
        try std.testing.expect(!ui.poisoned);
        try std.testing.expect(!cancel.isRequested());
    }
}
test "completed producer drains final events before bridge can reset" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();

    ui.prompt = try std.testing.allocator.dupe(u8, "fixture");
    ui.job = .{ .runtime = undefined, .cancel = &cancel, .prompt = ui.prompt.? };
    ui.busy = true;

    const Producer = struct {
        fn run(state: *Ui) void {
            const host = state.bridge.host();
            host.emit_fn(host.context, .{ .text = "old draft" }, state.cancel) catch unreachable;
            host.emit_fn(host.context, .{ .assistant_committed = &.{.{ .text = "canonical final" }} }, state.cancel) catch unreachable;
            state.job.terminal = .{ .status = .success };
            state.job.done.store(true, .release);
        }
    };

    ui.future = try Io.concurrent(std.testing.io, Producer.run, .{&ui});
    try ui.complete();

    // 收尾后草稿已清空，且最终内容不被标记为中断。
    try std.testing.expect(!ui.busy and ui.draft == null);
    try std.testing.expectEqualStrings("canonical final", ui.records.items[0].body.items);
    try std.testing.expect(!ui.records.items[0].interrupted);

    // 收尾后 bridge 必须可以安全复用。
    try bridge.reset();
}
test "local task ownership is announced once and released only after the join" {
    const Tracker = struct {
        begins: usize = 0,
        joins: usize = 0,
        fail_begin: bool = false,
        fn current(_: *anyopaque) Connection.State {
            return .{ .runtime = null, .model = "fixture", .base_url = "" };
        }
        fn begin(raw: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.fail_begin) return error.OwnerBusy;
            self.begins += 1;
        }
        fn joined(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.joins += 1;
        }
    };
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var tracker: Tracker = .{};
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.context = &tracker;
    ui.connection.current_fn = Tracker.current;
    ui.connection.task_begin_fn = Tracker.begin;
    ui.connection.task_joined_fn = Tracker.joined;

    // A failed begin publishes nothing and owes no release. The refused start
    // leaves the caller's input exactly as it was.
    try std.testing.expect(try ui.editor.insert("kept draft"));
    tracker.fail_begin = true;
    try std.testing.expectError(error.OwnerBusy, ui.beginTaskOwnership());
    try std.testing.expect(!ui.task_owned);
    try std.testing.expectEqual(@as(usize, 0), tracker.begins);
    try std.testing.expectEqual(@as(usize, 0), tracker.joins);
    try std.testing.expectEqualStrings("kept draft", ui.editor.bytes.items);

    tracker.fail_begin = false;
    try ui.beginTaskOwnership();
    try std.testing.expectEqual(@as(usize, 1), tracker.begins);
    try std.testing.expect(ui.task_owned);
    // A repeated begin never announces a second task.
    try ui.beginTaskOwnership();
    try std.testing.expectEqual(@as(usize, 1), tracker.begins);
    try std.testing.expectEqual(@as(usize, 0), tracker.joins);

    // The release happens only inside complete(), after the future is awaited.
    ui.prompt = try std.testing.allocator.dupe(u8, "fixture");
    ui.job = .{ .runtime = undefined, .cancel = &cancel, .prompt = ui.prompt.? };
    ui.busy = true;
    const Producer = struct {
        fn run(state: *Ui) void {
            state.job.terminal = .{ .status = .success };
            state.job.done.store(true, .release);
        }
    };
    ui.future = try Io.concurrent(std.testing.io, Producer.run, .{&ui});
    try std.testing.expectEqual(@as(usize, 0), tracker.joins);
    try std.testing.expect(ui.task_owned);
    try ui.complete();
    try std.testing.expectEqual(@as(usize, 1), tracker.joins);
    try std.testing.expect(!ui.task_owned);
    try std.testing.expect(!ui.busy);
    // A later completion of the same task cannot release ownership twice.
    try ui.complete();
    try std.testing.expectEqual(@as(usize, 1), tracker.joins);
    try std.testing.expectEqual(@as(usize, 1), tracker.begins);
}
test "remote sessions never announce a local task ownership" {
    const Tracker = struct {
        var begins: usize = 0;
        var joins: usize = 0;
        fn begin(_: *anyopaque) anyerror!void {
            begins += 1;
        }
        fn joined(_: *anyopaque) void {
            joins += 1;
        }
    };
    Tracker.begins = 0;
    Tracker.joins = 0;
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fake: FakeRemote = .{};
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.task_begin_fn = Tracker.begin;
    ui.connection.task_joined_fn = Tracker.joined;
    try std.testing.expect(ui.remote() != null);
    // The backend owns the task, so this view announces and releases nothing:
    // no second task may be started for an attached session.
    try ui.beginTaskOwnership();
    try std.testing.expect(!ui.task_owned);
    try std.testing.expectEqual(@as(usize, 0), Tracker.begins);
    ui.endTaskOwnership();
    try std.testing.expectEqual(@as(usize, 0), Tracker.joins);
}
test "upstream truncated permission preview is deny-only" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();

    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = "incomplete preview" } }, &cancel);
    var item = bridge.pop().?;
    item.display_truncated = true;
    try ui.event(item);
    item.deinit();

    try ui.draw();
    try std.testing.expect(ui.permission.?.clipped);
    try std.testing.expect(std.mem.find(u8, ui.frame, "deny only") != null);
    ui.displayed_permission = 1;
    ui.displayed_permission_choice = .deny;
    try Ui.key(&ui, .left); // Clipped previews cannot select Allow once.
    try std.testing.expectEqual(ApprovalChoice.deny, ui.permission.?.choice);
    try Ui.key(&ui, .{ .text = .{ .value = "y", .pasted = false } });
    try std.testing.expect(bridge.answer == null);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try Ui.key(&ui, .enter);
    try std.testing.expectEqual(@as(?r.Decision, .deny), bridge.answer);
}
test "permissions require a matching displayed frame and never accept paste" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 2, .tool_name = "bash", .description = "fixed fixture" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try Ui.key(&ui, .enter);
    try std.testing.expect(bridge.answer == null);
    ui.displayed_permission = 1;
    ui.displayed_permission_choice = .deny;
    try Ui.key(&ui, .enter);
    try std.testing.expect(bridge.answer == null);

    ui.displayed_permission = 2;
    ui.displayed_permission_choice = .deny;
    try Ui.key(&ui, .{ .text = .{ .value = "y", .pasted = true } });
    try std.testing.expect(bridge.answer == null);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    ui.displayed_permission = 2;
    ui.displayed_permission_choice = .deny;
    try Ui.key(&ui, .enter);
    try std.testing.expectEqual(@as(?r.Decision, .deny), bridge.answer);
}
test "inline approval preserves conversation and pages its plain preview" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection.current_fn = FixtureConnection.configuredCurrent;
    defer ui.deinit();
    _ = try ui.add(.user, "visible prior conversation");
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try bridge.host().emit_fn(&bridge, .{ .permission = .{ .id = 12, .tool_name = "bash", .description = "PREVIEW-1\nPREVIEW-2\nPREVIEW-3\nPREVIEW-4" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(screen.visible("visible prior conversation"));
    try std.testing.expect(std.mem.indexOf(u8, &screen.grid[screen.row], "Approval #12: [Allow once / > Deny]") != null);
    try std.testing.expect(screen.row >= 3);
    try std.testing.expect(std.mem.indexOf(u8, &screen.grid[screen.row - 3], "PREVIEW-1") != null);
    try std.testing.expect(screen.visible("PREVIEW-1"));
    try std.testing.expect(!screen.visible("PREVIEW-4"));
    try Ui.key(&ui, .end);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(screen.visible("PREVIEW-4"));
    try std.testing.expect(!screen.visible("PREVIEW-1"));
    try std.testing.expectEqual(@as(?ApprovalChoice, .deny), ui.displayed_permission_choice);
}
test "large approval pages retain the first and last rows with fresh ACK" {
    const a = std.testing.allocator;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "HEAD-PREVIEW\n");
    for (0..8200) |_| try source.appendSlice(a, "preview line\n");
    try source.appendSlice(a, "TAIL-PREVIEW");
    ui.permission = .{ .id = 12, .description = try a.dupe(u8, source.items), .clipped = false };
    try ui.draw();
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "HEAD-PREVIEW") != null);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .end);
    try std.testing.expect(ui.displayed_permission == null);
    try ui.draw();
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "TAIL-PREVIEW") != null);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(?u64, 12), ui.displayed_permission);
}
test "inline approval page keys cover every preview line" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection.current_fn = FixtureConnection.configuredCurrent;
    defer ui.deinit();
    const markers = [_][]const u8{ "PAGING-00", "PAGING-01", "PAGING-02", "PAGING-03", "PAGING-04", "PAGING-05", "PAGING-06", "PAGING-07", "PAGING-08", "PAGING-09" };
    try bridge.host().emit_fn(&bridge, .{ .permission = .{ .id = 12, .tool_name = "bash", .description = "PAGING-00\nPAGING-01\nPAGING-02\nPAGING-03\nPAGING-04\nPAGING-05\nPAGING-06\nPAGING-07\nPAGING-08\nPAGING-09" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    var seen = [_]bool{ false, false, false, false, false, false, false, false, false, false };
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    for (markers, 0..) |marker, i| seen[i] = screen.visible(marker);
    while (ui.permission_scroll <= markers.len) {
        try Ui.key(&ui, .page_down);
        try std.testing.expect(ui.displayed_permission == null);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
        for (markers, 0..) |marker, i| seen[i] = seen[i] or screen.visible(marker);
    }
    for (seen) |visible| try std.testing.expect(visible);
    while (ui.permission_scroll != 0) {
        try Ui.key(&ui, .page_up);
        try std.testing.expect(ui.displayed_permission == null);
        try ui.draw();
        try screen.replay(ui.frame);
        testAcknowledgeFullFrame(&ui);
    }
    try std.testing.expect(screen.visible(markers[0]));
}
test "inline approval shows deny-only reason after clipping or paste" {
    for ([_]bool{ false, true }) |pasted| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        try bridge.host().emit_fn(&bridge, .{ .permission = .{ .id = 12, .tool_name = "bash", .description = "plain preview" } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        if (pasted) {
            try Ui.key(&ui, .paste_start);
        } else {
            ui.permission.?.clipped = true;
            ui.permission.?.choice = .allow_once;
        }
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try ui.draw();
        try screen.replay(ui.frame);
        try std.testing.expect(screen.visible("plain preview"));
        try std.testing.expect(screen.visible(if (pasted) "paste detected; deny only" else "preview clipped; deny only"));
        try std.testing.expect(screen.visible("> Deny"));
        try std.testing.expect(!screen.visible("Allow once"));
        try std.testing.expectEqual(@as(?ApprovalChoice, .deny), ui.frame_permission_choice);
        testAcknowledgeFullFrame(&ui);
        try Ui.key(&ui, .left);
        try std.testing.expectEqual(ApprovalChoice.deny, ui.permission.?.choice);
        try std.testing.expect(bridge.answer == null);
    }
}
test "approval popup offers only one-shot allow or deny and text grants no authority" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const host = bridge.host();
    for ([_]u64{ 1, 2 }) |id| {
        try host.emit_fn(host.context, .{ .permission = .{ .id = id, .tool_name = "bash", .description = "explicit approval required" } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, "Allow once") != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "> Deny") != null);
        try std.testing.expect(std.mem.find(u8, ui.frame, "TRUST") == null);
        ui.displayed_permission = ui.frame_permission;
        ui.displayed_permission_choice = ui.frame_permission_choice;
        try Ui.key(&ui, .{ .text = .{ .value = "t", .pasted = false } });
        try std.testing.expect(bridge.answer == null);
        try std.testing.expectEqual(id, ui.permission.?.id);
        try std.testing.expectEqualStrings("", ui.editor.bytes.items);
        if (id == 1) try Ui.key(&ui, .left);
        ui.displayed_permission = id;
        ui.displayed_permission_choice = ui.permission.?.choice;
        try Ui.key(&ui, .enter);
        try std.testing.expectEqual(@as(?r.Decision, if (id == 1) .allow_once else .deny), bridge.answer);
        try std.testing.expect(ui.permission == null);
        try std.testing.expectEqual(if (id == 1) r.Decision.allow_once else .deny, try host.authorize_fn(host.context, .{ .id = id, .tool_name = "bash", .description = "explicit approval required" }, &cancel));
        discardFixtureFrame(&ui);
    }
}
test "approval allow requires the complete selected authority row" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 12, .rows = 7 }; // drawable cols = 11
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = "op" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try Ui.key(&ui, .left);
    try std.testing.expectEqual(ApprovalChoice.allow_once, ui.permission.?.choice);
    try std.testing.expect(!ui.approvalFits(1, .allow_once));
    try ui.draw();
    try std.testing.expect(ui.frame_permission == null);
    ui.displayed_permission = null;
    ui.displayed_permission_choice = null;
    try Ui.key(&ui, .enter);
    try std.testing.expect(bridge.answer == null);
    discardFixtureFrame(&ui);

    ui.size.columns = 17; // The complete identity and choices now fit within three rows.
    try ui.draw();
    try std.testing.expectEqual(@as(?u64, 1), ui.frame_permission);
    try std.testing.expectEqual(@as(?ApprovalChoice, .allow_once), ui.frame_permission_choice);
    ui.displayed_permission = ui.frame_permission;
    ui.displayed_permission_choice = ui.frame_permission_choice;
    try Ui.key(&ui, .enter);
    try std.testing.expectEqual(@as(?r.Decision, .allow_once), bridge.answer);
}
test "approval popup Escape denies without steering or an armed text byte" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 33, .tool_name = "bash", .description = "dangerous operation" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try ui.draw();
    ui.displayed_permission = ui.frame_permission;
    ui.displayed_permission_choice = ui.frame_permission_choice;
    try Ui.key(&ui, .escape);
    try std.testing.expectEqual(@as(?r.Decision, .deny), bridge.answer);
    try std.testing.expect(ui.permission == null);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
}
test "paste terminator injection cannot authorize the visible permission" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = "fixed fixture" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    ui.displayed_permission = 1;
    ui.displayed_permission_choice = .deny;

    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[200~\x1b[201~", sink);
    try ui.parser.feed("yt\x1b[201~", sink); // Malicious paste body after an embedded terminator.
    try std.testing.expect(bridge.answer == null);
    try std.testing.expect(ui.approval_paste_seen);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    ui.displayed_permission = 1;
    ui.displayed_permission_choice = .deny;
    try Ui.key(&ui, .enter);
    try std.testing.expectEqual(@as(?r.Decision, .deny), bridge.answer);
}
test "canonical reasoning is discarded even when clipped and body remains canonical" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();

    try ui.appendDraft(.reasoning, "old reasoning");
    try ui.replaceCommitted(&.{ .{ .reasoning = "bounded canonical reasoning" }, .{ .text = "canonical body" } }, true, true);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(Kind.assistant, ui.records.items[0].kind);
    try std.testing.expect(ui.records.items[0].clipped);
    try std.testing.expectEqualStrings("canonical body", ui.records.items[0].body.items);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "reasoning") == null);
    testAcknowledgeFullFrame(&ui);
}
test "six-row approval cannot authorize and recovers after a complete visible frame" {
    try text.initLocale();
    for ([_]usize{ 7, 24 }) |restored_rows| {
        for ([_]r.Decision{ .allow_once, .deny }) |decision| {
            var cancel = p.Cancellation{};
            var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
            defer bridge.deinit();
            var ui = fixtureUi(&bridge, &cancel);
            defer ui.deinit();
            ui.size = .{ .columns = 80, .rows = 6 };
            const host = bridge.host();
            try host.emit_fn(host.context, .{ .permission = .{ .id = 1, .tool_name = "bash", .description = "VISIBLE OPERATION" } }, &cancel);
            var item = bridge.pop().?;
            try ui.event(item);
            item.deinit();
            const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };

            try ui.draw();
            try std.testing.expect(std.mem.find(u8, ui.frame, "Resize terminal") != null);
            try std.testing.expect(std.mem.find(u8, ui.frame, "VISIBLE OPERATION") == null);
            try std.testing.expect(ui.frame_permission == null);
            ui.displayed_permission = ui.frame_permission; // 模拟整帧写完，不使用真实终端。
            ui.displayed_permission_choice = ui.frame_permission_choice;
            try ui.parser.feed("yt", sink);
            try std.testing.expect(bridge.answer == null);
            try std.testing.expect(!ui.permission.?.clipped);
            discardFixtureFrame(&ui);

            ui.size.rows = restored_rows;
            try ui.draw();
            try std.testing.expect(std.mem.find(u8, ui.frame, "VISIBLE OPERATION") != null);
            try std.testing.expectEqual(@as(?u64, 1), ui.frame_permission);
            try Ui.key(&ui, .enter); // 构建帧不等于整帧已显示。
            try std.testing.expect(bridge.answer == null);
            if (decision == .allow_once) try Ui.key(&ui, .left);
            ui.displayed_permission = ui.frame_permission;
            ui.displayed_permission_choice = ui.permission.?.choice;
            try Ui.key(&ui, .enter);
            try std.testing.expectEqual(@as(?r.Decision, decision), bridge.answer);
        }
    }
}
test "approval identity must fit in full before narrow windows can authorize" {
    try text.initLocale();
    for ([_]u64{ 1, std.math.maxInt(u64) }) |id| {
        var cancel = p.Cancellation{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        var buffer: [40]u8 = undefined;
        const identity = try std.fmt.bufPrint(&buffer, "Approval #{d}", .{id});
        ui.size = .{ .columns = identity.len, .rows = 7 };
        const host = bridge.host();
        try host.emit_fn(host.context, .{ .permission = .{ .id = id, .tool_name = "bash", .description = "OPERATION" } }, &cancel);
        var item = bridge.pop().?;
        try ui.event(item);
        item.deinit();
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.draw();
        try std.testing.expect(ui.frame_permission == null);
        try std.testing.expect(!ui.permission.?.clipped);
        // 即使还残留较宽窗口的旧帧确认，也不得在编号放不下时批准。
        ui.displayed_permission = id;
        ui.displayed_permission_choice = .allow_once;
        try ui.parser.feed("yt", sink);
        try std.testing.expect(bridge.answer == null);
        ui.displayed_permission = null;
        discardFixtureFrame(&ui);

        // The drawable width must contain both the identity and the selected
        // authority-bearing row; the last physical column remains unused.
        ui.size.columns = @max(identity.len, 16) + 1;
        try ui.draw();
        try std.testing.expect(std.mem.find(u8, ui.frame, identity) != null);
        try std.testing.expectEqual(@as(?u64, id), ui.frame_permission);
        try Ui.key(&ui, .left);
        try Ui.key(&ui, .enter);
        try std.testing.expect(bridge.answer == null);
        ui.displayed_permission = ui.frame_permission;
        ui.displayed_permission_choice = .allow_once;
        try Ui.key(&ui, .enter);
        try std.testing.expectEqual(@as(?r.Decision, .allow_once), bridge.answer);
    }
}
test "editor tabs expand before clipping and cursor placement but submit unchanged" {
    try text.initLocale();
    const cfg = @import("../core/config.zig");
    var config = cfg.Config{ .provider = .{ .base_url = "http://localhost/fixture" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = AuthFixture{ .configured = true };
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fixture, .call_fn = AuthFixture.call }, .{ .context = &fixture, .schemas = &.{}, .prepare_fn = AuthFixture.prepare, .execute_fn = AuthFixture.execute }, bridge.host(), "");
    defer runtime.deinit();
    fixture.runtime = &runtime;
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    ui.size = .{ .columns = 12, .rows = 7 };
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    const raw = "A\t\tB\t\tC";
    try ui.parser.feed("\x1b[200~" ++ raw ++ "\x1b[201~", sink);

    const cases = [_]usize{ raw.len, 3, 1 };
    for (cases) |cursor| {
        ui.editor.cursor = cursor;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const prepared = try ui.prepareComposer(arena.allocator(), ui.connection.current(), ui.size.columns -| 1);
        try ui.draw();
        try std.testing.expect(std.mem.findScalar(u8, ui.frame, '\t') == null);
        var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 12, .rows = 7 };
        try screen.replay(ui.frame);
        // The configured fixture has no notice, so the composer is the whole tail.
        try std.testing.expectEqual(prepared.layout.lines.len, ui.frame_height);
        try std.testing.expectEqual(screen.rows - prepared.layout.lines.len + prepared.layout.cursor_row, screen.row);
        try std.testing.expectEqual(text.width(prepared.decoration.plain) + prepared.layout.cursor_column, screen.col);
        try std.testing.expectEqualStrings(raw, ui.editor.bytes.items);
        discardFixtureFrame(&ui);
    }

    try ui.parser.feed("\r", sink);
    try std.testing.expectEqualStrings(raw, ui.prompt.?);
    try ui.complete();
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqualStrings(raw, runtime.messages()[0].blocks[0].text);
    try std.testing.expectEqualStrings(raw, ui.records.items[0].body.items);
}
test "unselected startup prompts login and model with no placeholder ID or budget" {
    const owner_default: Connection.State = .{ .runtime = null, .model = "fixture/hidden", .base_url = "" };
    try std.testing.expect(@TypeOf(owner_default.model_providers) == []const ModelProvider);
    try std.testing.expectEqual(@as(usize, 0), owner_default.model_providers.len);
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .name = "", .model_providers = &.{}, .low_price_input = true, .settings_notice = "Saved thinking level not applied" };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "/login, then /model") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "deepseek-flash") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "?%") == null);
    testAcknowledgeFullFrame(&ui);
    ui.openModelPicker();
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "No logged-in providers") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "fixture-next") == null);
    testAcknowledgeFullFrame(&ui);
    try ui.modelKey(.enter);
    try std.testing.expect(ui.model_picker != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
}
test "model selection and late default completion flash the actual logical level" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .effort = .medium };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.clock_ms = 123;
    try ui.selectModel("fixture-next");
    try std.testing.expectEqual(shared.ReasoningEffort.medium, ui.effort_flash.?.level);
    try std.testing.expectEqual(@as(u64, 5123), ui.effort_flash.?.until_ms);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("fixture-next) medium"));
    testAcknowledgeFullFrame(&ui);
    fixture.effort = .unspecified;
    fixture.levels = .{};
    fixture.pending_default = .high;
    try ui.selectModel("fixture-late");
    try std.testing.expect(ui.effort_flash == null);
    fixture.metadata_effort = .low; // The actual supported level can differ from the requested default.
    fixture.metadata_changed = true;
    ui.connection.poll_models_fn = SelectionFixture.pollMetadata;
    ui.clock_ms = 200;
    ui.pollMetadata();
    try std.testing.expectEqual(shared.ReasoningEffort.low, ui.effort_flash.?.level);
    try std.testing.expectEqual(@as(u64, 5200), ui.effort_flash.?.until_ms);
    try ui.draw();
    try std.testing.expectEqual(shared.ReasoningEffort.low, ui.display.reasoning_effort);
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("fixture-late) low"));
    testAcknowledgeFullFrame(&ui);
    ui.clock_ms = 5199;
    ui.pollMetadata(); // No changed metadata must not restart the deadline.
    fixture.metadata_changed = true;
    ui.pollMetadata(); // Even a changed poll without a pending transition must not restart it.
    try ui.draw();
    try std.testing.expectEqual(@as(u64, 5200), ui.effort_flash.?.until_ms);
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("fixture-late) low"));
    testAcknowledgeFullFrame(&ui);
    ui.clock_ms = 5200;
    ui.expireEffortFlash();
    try std.testing.expect(ui.effort_flash == null);
}
test "pending default thinking is explicit and never claims an effective wire option" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .effort = .unspecified };
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var state = fixture.connection().current();
    state.runtime = @ptrFromInt(@alignOf(r.Runtime)); // Hint reads no Runtime memory.
    state.pending_default_effort = .medium;
    const hint_line = try ui.hint(std.testing.allocator, state);
    defer std.testing.allocator.free(hint_line);
    try std.testing.expect(std.mem.find(u8, hint_line, "Default thinking: medium") != null);
    try std.testing.expect(std.mem.find(u8, hint_line, "awaiting model capabilities") != null);
    try std.testing.expectEqual(shared.ReasoningEffort.unspecified, state.reasoning_effort);
}
test "flat logged model list directly shows models and requires exact ACK" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    const profiles = [_]core_config.Model{
        .{ .name = "opencode-go/go-id", .context_tokens = 1000000 },
        .{ .name = "proxy/org/model", .context_tokens = 65536 },
        .{ .name = "not-logged/hidden-id", .context_tokens = 65536 },
    };
    const providers = [_]ModelProvider{ .{ .name = "opencode-go" }, .{ .name = "proxy", .allow_custom = true } };
    var fixture: SelectionFixture = .{ .name = "opencode-go/go-id", .profiles_override = &profiles, .model_providers = &providers };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openModelPicker();
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Search> ") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Provider> ") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "go-id") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "proxy/org/model") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "hidden-id") == null);
    testAcknowledgeFullFrame(&ui);
    try ui.modelKey(.left);
    try std.testing.expect(ui.model_picker == null and ui.commandMenuVisible());
    ui.openModelPicker();
    try ui.modelKey(.down);
    try ui.draw();
    try ui.modelKey(.enter); // A partial frame must not authorize the new row.
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    testAcknowledgeFullFrame(&ui);
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
    try std.testing.expectEqualStrings("proxy/org/model", fixture.name);
}
test "flat model confirmation rejects credential list replacement after ACK" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    const profiles = [_]core_config.Model{
        .{ .name = "first/model", .context_tokens = 65536 },
        .{ .name = "replacement/model", .context_tokens = 65536 },
    };
    var fixture: SelectionFixture = .{ .name = "first/model", .profiles_override = &profiles, .model_providers = &.{.{ .name = "first" }} };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openModelPicker();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    fixture.model_providers = &.{.{ .name = "replacement" }};
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.modelKey(.enter);
    try std.testing.expectEqualStrings("replacement/model", fixture.name);
}
test "model picker rejects disabled unknown protocol even after frame acknowledgement" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .disabled_models = &.{true} };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.size = .{ .columns = 100, .rows = 24 };
    ui.openModelPicker();
    try ui.modelKey(.down);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Protocol unknown") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try std.testing.expect(ui.model_picker != null);
    // Disabling a row after its acknowledged frame is also checked at Enter.
    fixture.disabled_models = &.{};
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    fixture.disabled_models = &.{true};
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
}
test "metadata refresh command excludes paste and revokes picker confirmation after catalog changes" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.connection.refresh_models_fn = SelectionFixture.refreshMetadata;
    ui.connection.poll_models_fn = SelectionFixture.pollMetadata;
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/model --refresh\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.refreshes);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    try ui.parser.feed("\x1b[200~/model --refresh\x1b[201~\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.refreshes);
    ui.openModelPicker();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    fixture.metadata_changed = true;
    ui.pollMetadata();
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
}
test "green checked candidates preserve full multibyte IDs and configured label spacing" {
    const a = std.testing.allocator;
    try text.initLocale();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const name = try a.alloc(u8, 510);
    defer a.free(name);
    for (0..170) |i| @memcpy(name[i * 3 ..][0..3], "模");
    const value = try std.fmt.allocPrint(a, "> ✓ {s}", .{name});
    defer a.free(value);
    try putCandidateLine(&out.writer, a, 1, value, 400, theme.accent, true);
    try std.testing.expect(std.mem.find(u8, out.written(), name) != null);
    try std.testing.expect(std.mem.find(u8, out.written(), theme.success ++ "✓" ++ theme.accent) != null);
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .provider_hint = .deepseek, .configured_providers = 1 };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openProviderPicker();
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.success ++ "✓" ++ theme.accent ++ " DeepSeek") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "configured locally") == null);
}
test "Image settings default Off isolated callbacks search Back and explicit Off" {
    try text.initLocale();
    var fixture: ImageModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    try std.testing.expect(!fixture.state.image_enabled);
    try std.testing.expect((Connection.State{ .runtime = null, .model = "", .base_url = "" }).image_models.len == 0);
    ui.openSettingsMenu();
    ui.settings_menu.selected = 5;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expect(ui.settings_model_picker == .image and ui.settings_menu.selected == 0);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "login/deepseek-flash") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "unlogged/deepseek-flash") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "family/judge") == null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("no-match", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "No matching models") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try Ui.key(&ui, .clear);
    try ui.parser.feed("FLASH login", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(fixture.state.image_enabled and ui.settings_model_picker != .image and ui.settings_menu.selected == 5);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    try std.testing.expectEqualStrings("login/family/judge", fixture.state.decision_model.?);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.settings_model_picker == .image and ui.settings_menu.selected == 1);
    try ui.parser.feed("\x1b[A", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!fixture.state.image_enabled and ui.settings_menu.selected == 5);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\rquery\x1b[D\r", sink); // Root open discards the entire tail.
    try std.testing.expect(ui.settings_model_picker == .image and ui.editor.bytes.items.len == 0);
    try ui.parser.feed("query\x1b[D\r", sink);
    try std.testing.expect(ui.settings_model_picker != .image and ui.settings_menu.selected == 5 and ui.editor.bytes.items.len == 0);
    ui.settings_menu.selected = 1;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.settings_model_picker == .decision);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.decision_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqualStrings("primary", fixture.state.model);
}
test "Image settings fresh ACK pending partial resize changed candidates paste failed saves" {
    try text.initLocale();
    var fixture: ImageModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    ui.settings_menu.selected = 5;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    try ui.parser.feed("\r", sink);
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    testAcknowledgeFullFrame(&ui);
    var replaced = ImageModelFixture.profiles;
    replaced[0].name = "login/replaced";
    fixture.state.image_models = &replaced;
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    fixture.state.image_models = &ImageModelFixture.profiles;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const size = ui.size;
    ui.resize(.{ .columns = 8, .rows = size.rows });
    ui.resize(size);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    fixture.fail = true;
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(ui.settings_model_picker == .image and !fixture.state.image_enabled);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    fixture.fail = false;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~flash\x1b[201~\r", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    ui.closeSettingsMenu();
    try std.testing.expect(ui.settings_model_picker == .none and ui.editor.bytes.items.len == 0);
    try std.testing.expect(ui.displayed_decision_fingerprint == null and ui.frame_decision_fingerprint == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.decision_calls);
}
test "Decision direct list isolates selection and consumes failed save ACK and input batch" {
    try text.initLocale();
    var fixture: DecisionModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try ui.parser.feed("\x1b[B", sink);
    try std.testing.expect(ui.settings_open and ui.settings_model_picker == .decision and ui.model_picker == null);
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "login/family/judge") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "unlogged/private-model") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "second/family/judge") == null);
    try ui.parser.feed("\r", sink);
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    testAcknowledgeFullFrame(&ui);
    // Same-index rename, protocol-only replacement, and logout all revoke ACK.
    var replacement = DecisionModelFixture.profiles;
    for (0..3) |scenario| {
        if (scenario != 0) try ui.draw();
        replacement = DecisionModelFixture.profiles;
        switch (scenario) {
            0 => {
                replacement[0].name = "login/replaced/Judge";
                fixture.state.decision_models = &replacement;
            },
            1 => {
                replacement[0].protocol = .responses;
                fixture.state.decision_models = &replacement;
            },
            2 => fixture.state.model_providers = &.{},
            else => unreachable,
        }
        if (scenario != 0) testAcknowledgeFullFrame(&ui); // Publish only the frame's old identity.
        try ui.parser.feed("\r\r", sink);
        try std.testing.expectEqual(@as(usize, 0), fixture.calls);
        fixture.state.decision_models = &DecisionModelFixture.profiles;
        fixture.state.model_providers = &DecisionModelFixture.logged;
        try ui.parser.feed("\r", sink); // Owner ABA cannot restore consumed ACK.
        try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    }
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    // The same raw ID on a different newly visible alias cannot inherit ACK.
    fixture.state.model_providers = &DecisionModelFixture.other;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    fixture.state.model_providers = &DecisionModelFixture.logged;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const size = ui.size;
    ui.resize(.{ .columns = 8, .rows = size.rows });
    ui.resize(size);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    fixture.fail = true;
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(ui.settings_model_picker == .decision and !fixture.state.decision_enabled);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    fixture.fail = false;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r\x1b[A", sink);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqualStrings("login/family/judge", fixture.saved[0..fixture.saved_len]);
    try std.testing.expectEqual(@as(usize, 0), fixture.main_calls);
    try std.testing.expectEqualStrings("primary", fixture.state.model);
    try std.testing.expect(ui.settings_open and ui.settings_model_picker != .decision and ui.model_picker == null);
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.settings_model_picker == .decision and ui.settings_menu.selected == 1);
    try ui.parser.feed("\x1b[D\r", sink);
    try std.testing.expect(ui.settings_open and ui.settings_model_picker != .decision and ui.settings_menu.selected == 1);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}
test "Decision list offers Off without providers and never invents search identities or accepts paste" {
    try text.initLocale();
    var fixture: DecisionModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    fixture.state.decision_model = "login/ghost-current";
    fixture.state.model_providers = &.{};
    ui.openSettingsMenu();
    ui.settings_model_picker = .decision;
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "login/family/judge") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "ghost-current") == null);
    try std.testing.expect(ui.frame_settings_generation != null); // Off remains available.
    testAcknowledgeFullFrame(&ui);
    fixture.state.model_providers = &DecisionModelFixture.logged;
    try ui.parser.feed("\r", sink); // Availability changed since ACK, even for Off.
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.parser.feed("arbitrary-raw-id", sink);
    ui.settings_menu.selected = 1;
    try ui.draw();
    try std.testing.expect(ui.model_picker == null);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .escape);
    try std.testing.expect(ui.settings_open and ui.settings_model_picker != .decision and ui.settings_menu.selected == 1);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.settings_model_picker == .decision);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~login/family/judge\x1b[201~\r", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.main_calls);
}
test "Decision search edits revoke query ACK including pending frames and clear on return" {
    try text.initLocale();
    var fixture: DecisionModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    ui.settings_model_picker = .decision;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("LOGIN FAMILY/JUDGE\r", sink);
    try std.testing.expectEqualStrings("LOGIN FAMILY/JUDGE", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), ui.settings_menu.selected);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Search> ") != null);
    // An edit while the old query frame is in flight must revoke its ACK too.
    try ui.parser.feed("x", sink);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "No matching models") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[A\x1b[B\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.parser.feed("\x7f", sink);
    try std.testing.expectEqualStrings("LOGIN FAMILY/JUDGE", ui.editor.bytes.items);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    // Query changes and changes back cannot resurrect the old identity proof.
    try ui.parser.feed("x\x7f\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(ui.settings_model_picker != .decision and ui.editor.bytes.items.len == 0);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "login/family/judge") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.settings_model_picker == .decision and ui.editor.bytes.items.len == 0);
    try ui.parser.feed("oFf\x15missing", sink);
    try std.testing.expectEqualStrings("missing", ui.editor.bytes.items);
    try Ui.key(&ui, .escape);
    try std.testing.expect(ui.settings_model_picker != .decision and ui.editor.bytes.items.len == 0);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    const large: [257]u8 = @splat('x');
    try Ui.key(&ui, .{ .text = .{ .value = &large, .pasted = false } });
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    try Ui.key(&ui, .{ .text = .{ .value = large[0..256], .pasted = false } });
    try std.testing.expectEqual(@as(usize, 256), ui.editor.bytes.items.len);
    try Ui.key(&ui, .clear);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    try Ui.key(&ui, .{ .text = .{ .value = "login", .pasted = false } });
    ui.closeSettingsMenu();
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    try std.testing.expectEqualStrings("Command timeout (s)", Ui.settingsValueTitle(.command_timeout_ms));
    try std.testing.expect(std.mem.find(u8, Ui.settingsValueTitle(.request_timeout_ms), "(s;") != null);
}
test "Decision search clips UTF8 controls and tiny windows without granting authority" {
    try text.initLocale();
    var fixture: DecisionModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_model_picker = .decision;
    try ui.settingsKey(.{ .text = .{ .value = "中文中文中文中文中文\x1b[2J", .pasted = false } });
    for ([_]terminal_module.Size{ .{ .columns = 0, .rows = 0 }, .{ .columns = 8, .rows = 6 }, .{ .columns = 18, .rows = 8 }, .{ .columns = 40, .rows = 12 } }) |size| {
        ui.resize(size);
        try ui.draw();
        try std.testing.expect(std.unicode.utf8ValidateSlice(ui.frame));
        try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[2J") == null);
        testAcknowledgeFullFrame(&ui);
        try ui.settingsKey(.enter);
        try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    }
    try ui.settingsKey(.home);
    try ui.settingsKey(.delete);
    try std.testing.expect(std.mem.startsWith(u8, ui.editor.bytes.items, "文中文"));
    try ui.settingsKey(.end);
    try ui.settingsKey(.kill_end);
    try ui.settingsKey(.cancel);
    try std.testing.expect(ui.settings_open and ui.settings_model_picker != .decision and ui.editor.bytes.items.len == 0);
}
test "Decision search OOM preserves bytes but revokes every old ACK" {
    var fixture: DecisionModelFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_model_picker = .decision;
    ui.displayed_settings_generation = ui.settings_menu.generation;
    ui.frame_settings_generation = ui.settings_menu.generation;
    ui.displayed_decision_fingerprint = decision_picker_module.fingerprint(fixture.state.decision_models, fixture.state.model_providers);
    ui.frame_decision_fingerprint = ui.displayed_decision_fingerprint;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    ui.editor.allocator = failing.allocator();
    defer ui.editor.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, ui.settingsKey(.{ .text = .{ .value = "judge", .pasted = false } }));
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try std.testing.expect(ui.displayed_settings_generation == null and ui.frame_settings_generation == null);
    try std.testing.expect(ui.displayed_decision_fingerprint == null and ui.frame_decision_fingerprint == null);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}
test "settings TUI custom seconds stages equivalent milliseconds" {
    try text.initLocale();
    var fixture: PreferenceFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 3;
    ui.openSettingsValue(.command_timeout_ms, fixture.state);
    ui.settings_menu.selected = try customPreferenceOption(ui.settings_value_picker.?);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(std.mem.find(u8, ui.notice, "seconds") != null);
    try ui.settingsKey(.{ .text = .{ .value = "123.456", .pasted = false } });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(u32, 123456), fixture.state.limits.command_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}
test "Auto memory root toggles only after fresh ACK without overlays and preserves failed save" {
    try text.initLocale();
    var fixture: PreferenceFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    ui.settings_menu.selected = 6;
    try ui.draw();
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(!fixture.state.memory_auto);
    try std.testing.expect(ui.settings_value_picker == null and !ui.settingsModelOpen());
    try std.testing.expect(ui.settings_open and ui.settings_menu.selected == 6);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    fixture.fail = true;
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expect(!fixture.state.memory_auto);
    try std.testing.expect(ui.settings_value_picker == null and !ui.settingsModelOpen());
    fixture.fail = false;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(fixture.state.memory_auto);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
}
test "settings numeric child consumes ACK before failed save and preserves parent" {
    try text.initLocale();
    var fixture: PreferenceFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    ui.settings_menu.selected = 2;
    try ui.draw();
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(!fixture.state.limits.compaction_enabled);
    ui.settings_menu.selected = 3;
    ui.openSettingsValue(.command_timeout_ms, fixture.state);
    ui.settings_menu.selected = try preferenceOption(ui.settings_value_picker.?, 60000);
    try ui.draw();
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    testAcknowledgeFullFrame(&ui);
    const size = ui.size;
    ui.resize(.{ .columns = 8, .rows = size.rows });
    ui.resize(size);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    fixture.fail = true;
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(u32, 300000), fixture.state.limits.command_timeout_ms);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    fixture.fail = false;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r\x1b[B", sink);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try std.testing.expectEqual(@as(u32, 60000), fixture.state.limits.command_timeout_ms);
    try std.testing.expect(ui.settings_value_picker == null and ui.settings_menu.selected == 3 and ui.settings_open);
    try std.testing.expectEqualStrings("unchanged-primary", fixture.state.model);
}
test "settings custom request timeout stages before a second fresh ACK and preserves parent" {
    try text.initLocale();
    var fixture: PreferenceFixture = .{};
    fixture.state.limits.request_timeout_ms = 1024;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    ui.settings_menu.selected = 4;
    ui.openSettingsValue(.request_timeout_ms, fixture.state);
    ui.settings_menu.selected = try customPreferenceOption(ui.settings_value_picker.?);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expect(ui.settings_value_picker.?.editing);
    try ui.parser.feed("\x158.192\r", sink);
    try std.testing.expect(ui.settings_value_picker.?.editing);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expect(!ui.settings_value_picker.?.editing);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(u32, 1024), fixture.state.limits.request_timeout_ms);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(@as(u32, 8192), fixture.state.limits.request_timeout_ms);
    try std.testing.expect(ui.settings_value_picker == null and ui.settings_menu.selected == 4);
    ui.openSettingsValue(.request_timeout_ms, fixture.state);
    ui.settings_menu.selected = try preferenceOption(ui.settings_value_picker.?, 300000);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(u32, 300000), fixture.state.limits.request_timeout_ms);
    try std.testing.expect(ui.settings_value_picker == null and ui.settings_menu.selected == 4);
}
test "settings shared request timeout rejects pasted numbers and preserves parent" {
    try text.initLocale();
    var fixture: PreferenceFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    ui.settings_menu.selected = 4;
    ui.openSettingsValue(.request_timeout_ms, fixture.state);
    ui.settings_menu.selected = try customPreferenceOption(ui.settings_value_picker.?);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try ui.parser.feed("\x1b[200~1000\r\x1b[201~\r", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expect(ui.settings_value_picker.?.editing);
    try ui.parser.feed("\x1b[D\r", sink);
    try std.testing.expect(!ui.settings_value_picker.?.editing);
    try ui.parser.feed("\x1b[D\r", sink);
    try std.testing.expect(ui.settings_value_picker == null and ui.settings_model_picker != .decision and ui.settings_menu.selected == 4);
    ui.openSettingsValue(.request_timeout_ms, fixture.state);
    ui.settings_menu.selected = try preferenceOption(ui.settings_value_picker.?, 60000);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(@as(u32, 60000), fixture.state.limits.request_timeout_ms);
    try std.testing.expect(ui.settings_model_picker != .decision and !fixture.state.decision_enabled and ui.settings_menu.selected == 4);
}
test "settings callbacks owner publication ACK paste batch and cursor" {
    try text.initLocale();
    const Fixture = struct {
        state: Connection.State = .{ .runtime = null, .model = "fixture", .base_url = "", .decision_models = &DecisionModelFixture.profiles, .model_providers = &DecisionModelFixture.logged },
        calls: usize = 0,
        fail: bool = false,
        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.state;
        }
        fn configure(_: *anyopaque, _: []const u8) !void {}
        fn choose(raw: *anyopaque, choice: Connection.DecisionChoice) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.fail) return error.SaveFailed;
            self.state.decision_enabled = choice != .off;
            self.state.decision_model = switch (choice) {
                .off => null,
                .model => |name| name,
            };
            self.state.initial_context = .{ .tokens = 42, .limit = 100 };
        }
        fn save(raw: *anyopaque, setting: Connection.Setting, enabled: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.fail) return error.SaveFailed;
            switch (setting) {
                .low_price_input => self.state.low_price_input_enabled = enabled,
                .decision_enabled => self.state.decision_enabled = enabled,
            }
        }
    };
    var fixture: Fixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = .{ .context = &fixture, .current_fn = Fixture.current, .configure_fn = Fixture.configure, .setting_fn = Fixture.save, .decision_fn = Fixture.choose };
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/settings\r\r", sink);
    try std.testing.expect(ui.settings_open);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.draw();
    try ui.parser.feed("\r", sink); // No complete ACK.
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 10), screen.col);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r\x1b[B", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(!fixture.state.low_price_input_enabled and ui.settings_menu.selected == 0);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.settings_model_picker == .decision and !fixture.state.decision_enabled);
    const before_choice = fixture.calls;
    try ui.parser.feed("\x1b[B\r", sink); // Stale navigation cannot confirm.
    try std.testing.expectEqual(before_choice, fixture.calls);
    try ui.draw();
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink); // Partial child output cannot confirm.
    try std.testing.expectEqual(before_choice, fixture.calls);
    testAcknowledgeFullFrame(&ui);
    // Save the direct identity without changing chat.
    try ui.parser.feed("\r\r\x1b[A", sink);
    try std.testing.expect(fixture.state.decision_enabled);
    try std.testing.expectEqualStrings("login/family/judge", fixture.state.decision_model.?);
    try std.testing.expect(ui.settings_model_picker != .decision and ui.settings_menu.selected == 1);
    try std.testing.expectEqual(@as(u32, 42), ui.display.context.?.tokens);
    fixture.fail = true;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink); // Open the selected model, not toggle.
    try std.testing.expect(ui.settings_model_picker == .decision);
    try ui.parser.feed("\x1b[A", sink); // Off.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(fixture.state.decision_enabled);
    try std.testing.expectEqualStrings("Could not save setting; previous value kept", ui.notice);
    const calls = fixture.calls;
    try ui.parser.feed("\r", sink); // Failed save revoked authority.
    try std.testing.expectEqual(calls, fixture.calls);
    try ui.parser.feed("\x1b[D\r", sink); // Left discards read tail, retains Decision.
    try std.testing.expect(ui.settings_model_picker != .decision and ui.settings_menu.selected == 1);
    try std.testing.expectEqual(calls, fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.settings_model_picker == .decision);
    try Ui.key(&ui, .escape);
    try std.testing.expect(ui.settings_model_picker != .decision and ui.settings_menu.selected == 1);
    try std.testing.expectEqual(calls, fixture.calls);
    fixture.state.global_settings_available = false;
    try ui.parser.feed("\x1b[A", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    fixture.state.global_settings_available = true;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const original = ui.size;
    ui.resize(.{ .columns = 8, .rows = original.rows });
    ui.resize(original); // Resize ABA cannot restore authority.
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    ui.resize(.{ .columns = 12, .rows = original.rows });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    ui.resize(original);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~pasted\x1b[201~\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(calls, fixture.calls);
    try ui.parser.feed("\x1b[D", sink);
    try std.testing.expect(!ui.settings_open);
    try std.testing.expectEqual(command_menu_module.Command.settings, ui.command_menu.choice(ui.command_matches).?);
}
test "decision child requires full fresh unclipped ACK and never saves pasted batch tails" {
    try text.initLocale();
    const Fixture = struct {
        state: Connection.State = .{ .runtime = null, .model = "", .base_url = "", .decision_models = &DecisionModelFixture.profiles, .model_providers = &DecisionModelFixture.logged },
        calls: usize = 0,
        fn current(raw: *anyopaque) Connection.State {
            return @as(*@This(), @ptrCast(@alignCast(raw))).state;
        }
        fn configure(_: *anyopaque, _: []const u8) !void {}
        fn choose(raw: *anyopaque, choice: Connection.DecisionChoice) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.state.decision_enabled = choice != .off;
            self.state.decision_model = switch (choice) {
                .off => null,
                .model => |name| name,
            };
        }
    };
    var fixture: Fixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = .{ .context = &fixture, .current_fn = Fixture.current, .configure_fn = Fixture.configure, .decision_fn = Fixture.choose };
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    ui.openSettingsMenu();
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink);
    try std.testing.expect(ui.settings_model_picker == .decision);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    try ui.parser.feed("\r", sink);
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    testAcknowledgeFullFrame(&ui);
    const size = ui.size;
    ui.resize(.{ .columns = 8, .rows = size.rows });
    ui.resize(size);
    try ui.parser.feed("\r", sink); // Resize ABA.
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    ui.resize(.{ .columns = 17, .rows = size.rows });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink); // Complete provider/raw ID does not fit.
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    ui.resize(size);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~\r\x1b[D\x1b[201~\r", sink);
    try std.testing.expect(ui.settings_model_picker == .decision);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try ui.parser.feed("\x1b[D\r", sink);
    try std.testing.expect(ui.settings_model_picker != .decision and ui.settings_menu.selected == 1);
    try ui.parser.feed("\r", sink); // Old child ACK cannot open parent.
    try std.testing.expect(ui.settings_model_picker != .decision);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.settings_model_picker == .decision);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\r", sink); // Off works without a declaration.
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(!fixture.state.decision_enabled and ui.settings_model_picker != .decision);
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
    try std.testing.expect(ui.displayed_settings_generation == null and ui.frame_settings_generation == null);
}
test "menus stay above composer share colors and Left returns to acknowledged parent" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    _ = try ui.add(.assistant, "menu-prior-answer");
    try ui.parser.feed("/", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[B\r", sink); // Move to login, but no fresh ACK yet.
    try std.testing.expect(!ui.provider_open and !ui.secret_mode);
    try std.testing.expectEqual(command_menu_module.Command.auth, ui.command_menu.choice(ui.command_matches).?);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "> /login") != null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const model_row = try rowStartingWith(&screen, "  /model");
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[model_row + 1], "> /login"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[model_row + 2], "  /compact"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("menu-prior-answer"));
    try ui.parser.feed("\r", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ ">   Current endpoint") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.muted ++ "    DeepSeek") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "Provider> " ++ theme.reset) != null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const endpoint_row = try rowStartingWith(&screen, ">   Current endpoint");
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[endpoint_row + 3], "    OpenCode Go"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[screen.row], "Provider> "));
    try ui.parser.feed("\x1b[D\r", sink);
    try std.testing.expect(!ui.provider_open and !ui.secret_mode);
    try std.testing.expectEqual(command_menu_module.Command.auth, ui.command_menu.choice(ui.command_matches).?);
    try ui.parser.feed("\x1b[A", sink); // Return from login to model.
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.success ++ "✓" ++ theme.accent ++ " fixture/fixture-old") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.muted ++ "    fixture/fixture-next") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "Search> " ++ theme.reset) != null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const selected_model_row = try rowStartingWith(&screen, "> ~ fixture/fixture-old");
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[selected_model_row + 1], "    fixture/fixture-next"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[screen.row], "Search> "));
    try ui.parser.feed("\t\x1b[5~\x1b[6~", sink);
    try std.testing.expectEqual(@as(usize, 0), ui.model_picker.?.selected);
    try std.testing.expectEqualStrings("", ui.model_picker.?.query.bytes.items);
    try ui.parser.feed("\x1b[D", sink);
    try std.testing.expect(ui.model_picker == null and ui.commandMenuVisible());
    try std.testing.expectEqual(command_menu_module.Command.model, ui.command_menu.choice(ui.command_matches).?);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
}
test "model popup shows at most ten bottom rows and keeps the selected item visible" {
    try text.initLocale();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var profiles: [12]core_config.Model = undefined;
    for (&profiles, 0..) |*profile, index| profile.* = .{
        .name = try std.fmt.allocPrint(arena.allocator(), "fixture/menu-{d:0>2}", .{index}),
        .context_tokens = 32768,
    };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .profiles_override = &profiles };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openModelPicker();
    try ui.modelKey(.up);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ ">   fixture/menu-11") != null);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    var count: usize = 0;
    for (screen.grid) |line| if (std.mem.find(u8, &line, "menu-") != null) {
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 10), count);
    // Ten bottom-pinned rows end with the selection; the composer stays below.
    const selected_row = try rowStartingWith(&screen, ">   fixture/menu-11");
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[selected_row - 9], "    fixture/menu-02"));
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[screen.row], "Search> "));
}
test "secret Escape cancels and Left returns to provider without leaking paste tails" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .provider_hint = .deepseek };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/login\r\x1b[B", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try ui.parser.feed("fake-ui-key", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, theme.accent ++ "API key> " ++ theme.reset) != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "fake-ui-key") == null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[Ddiscard-tail", sink);
    try std.testing.expect(ui.provider_open and !ui.secret_mode and ui.secret.len == 0);
    try std.testing.expectEqual(core_config.providers.Id.opencode_zen, ui.provider_choices.items[ui.provider_picker.selected].provider);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    for (ui.secret.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode); // Newly reopened parent needs ACK.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try ui.parser.feed("\x1b[200~fake-ui-key\x1b[201~\x1b[Ddiscard", sink);
    try std.testing.expect(ui.secret_mode and !ui.provider_open);
    try ui.parser.feed("\x1b", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(!ui.secret_mode and !ui.secret_quarantine and ui.secret.len == 0);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), fixture.provider_saves);
    for (ui.secret.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
test "metadata success publishes one transcript notice from an owner transition" {
    const Fixture = struct {
        notice: ?[]const u8 = null,
        next: ?[]const u8 = "Official model list refreshed",
        ttl: u16 = 3000,
        runtime: r.Runtime = undefined,
        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .runtime = &self.runtime, .model = "fixture", .base_url = "", .metadata_notice = self.notice, .metadata_notice_ttl_ms = self.ttl };
        }
        fn poll(raw: *anyopaque, _: bool) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.notice = self.next;
            return true;
        }
    };
    var fixture: Fixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.context = &fixture;
    ui.connection.current_fn = Fixture.current;
    ui.connection.poll_models_fn = Fixture.poll;
    _ = try ui.editor.insert("kept draft");
    ui.notice = "Refreshing official model metadata...";
    ui.clock_ms = 100;
    ui.pollMetadata();
    // Ordinary success is a one-shot display record; the footer returns to the
    // actionable default instead of owning a timer.
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(Kind.notice, ui.records.items[0].kind);
    try std.testing.expectEqualStrings(fixture.next.?, ui.records.items[0].body.items);
    try std.testing.expectEqualStrings("", try ui.hint(std.testing.allocator, ui.connection.current()));
    // Repeated identical snapshots, even far in the future, never duplicate the
    // record, hide the draft or stage a timer-driven frame.
    ui.pollMetadata();
    ui.clock_ms = 999_999;
    ui.pollMetadata();
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqualStrings("kept draft", ui.editor.bytes.items);

    // A later owner transition publishes exactly one more record.
    fixture.notice = null;
    ui.clock_ms = 4000;
    ui.pollMetadata();
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqual(Kind.notice, ui.records.items[1].kind);
    // The distinct failure is one warning in the conversation, never a footer.
    fixture.next = "Official metadata refresh failed; cached/default values kept";
    fixture.ttl = 0;
    ui.pollMetadata();
    try std.testing.expectEqualStrings(fixture.next.?, ui.notice);
    try std.testing.expectEqual(@as(usize, 3), ui.records.items.len);
    try std.testing.expectEqual(Kind.notice, ui.records.items[2].kind);
    try std.testing.expectEqual(NoticeLevel.warning, ui.records.items[2].notice_level);
    try std.testing.expectEqualStrings(fixture.next.?, ui.records.items[2].body.items);
    ui.observeAdvisories();
    ui.pollMetadata();
    ui.observeAdvisories();
    try std.testing.expectEqual(@as(usize, 3), ui.records.items.len);
    try std.testing.expectEqualStrings("", try ui.hint(std.testing.allocator, ui.connection.current()));
}
test "memory notice owner poll dirties UI without replacing foreground notice" {
    const Fixture = struct {
        view: @import("../core/memory_status.zig").View = .{},
        changed: bool = false,
        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .runtime = null, .model = "fixture", .base_url = "", .memory = self.view };
        }
        fn poll(raw: *anyopaque, _: bool) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const changed = self.changed;
            self.changed = false;
            return changed;
        }
    };
    var fixture: Fixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.context = &fixture;
    ui.connection.current_fn = Fixture.current;
    ui.connection.poll_models_fn = Fixture.poll;
    ui.notice = "Foreground error";
    inline for (.{ true, false }) |enabled| {
        fixture.view = .{ .enabled = enabled, .active = if (enabled) .{ .id = 1, .phase = .extracting } else null };
        fixture.changed = true;
        ui.dirty = false;
        ui.pollMetadata();
        try std.testing.expect(ui.dirty);
        try std.testing.expectEqualStrings("Foreground error", ui.notice);
        ui.dirty = false;
        ui.pollMetadata();
        try std.testing.expect(!ui.dirty); // Identical snapshot is not a transition.
    }
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
}
test "background and memory indicators animate independently while idle" {
    const Fixture = struct {
        count: usize = 1,
        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .runtime = null, .available = true, .model = "fixture", .base_url = "", .background = .{ .active_count = self.count }, .memory = .{ .enabled = true, .active = .{ .id = 1, .phase = .extracting } } };
        }
    };
    var fixture: Fixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.context = &fixture;
    ui.connection.current_fn = Fixture.current;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    ui.clock_ms = 80;
    ui.dirty = false;
    ui.animate();
    try std.testing.expect(ui.dirty);
    const first = try ui.hint(arena.allocator(), Fixture.current(&fixture));
    try std.testing.expect(std.mem.indexOf(u8, first, "M: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "B: ") != null);
    ui.clock_ms = 160;
    ui.dirty = false;
    ui.animate();
    try std.testing.expect(ui.dirty);
    fixture.count = 3;
    const multiple = try ui.hint(arena.allocator(), Fixture.current(&fixture));
    try std.testing.expect(std.mem.indexOf(u8, multiple, " 3") != null);
    fixture.count = 0;
    const none = try ui.hint(arena.allocator(), Fixture.current(&fixture));
    try std.testing.expect(std.mem.indexOf(u8, none, "B: ") == null);
    ui.secret_mode = true;
    try std.testing.expect(!ui.backgroundAnimating());
}
test "background completion is admitted before exact-id retirement" {
    const Fixture = struct {
        fn current(_: *anyopaque) Connection.State {
            return .{ .runtime = null, .available = true, .model = "fixture", .base_url = "" };
        }
        pending: ?background_status.Terminal = .{ .id = background_status.Id.from("job"), .command = background_status.Command.from("中文😀"), .result = .failed, .duration_ms = 1234, .exit_code = 7, .failure = .exit },
        takes: usize = 0,
        fn peek(raw: *anyopaque) ?background_status.Terminal {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.pending;
        }
        fn take(raw: *anyopaque, id: background_status.Id) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.pending) |*terminal| {
                if (std.mem.eql(u8, terminal.id.slice(), id.slice())) {
                    self.pending = null;
                    self.takes += 1;
                }
            }
        }
    };
    var fixture: Fixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.context = &fixture;
    ui.connection.current_fn = Fixture.current;
    ui.connection.peek_background_fn = Fixture.peek;
    ui.connection.take_background_fn = Fixture.take;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    ui.allocator = failing.allocator();
    ui.pollBackgroundCompletion();
    ui.allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), fixture.takes);
    try std.testing.expectEqualStrings("job", fixture.pending.?.id.slice());
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    ui.pollBackgroundCompletion();
    ui.pollBackgroundCompletion();
    try std.testing.expectEqual(@as(usize, 1), fixture.takes);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    const row = ui.records.items[0];
    try std.testing.expect(row.single_row);
    try std.testing.expectEqual(NoticeLevel.failure, row.notice_level);
    try std.testing.expect(std.mem.indexOf(u8, row.body.items, "exit 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, row.body.items, "1234ms") != null);
    ui.size = .{ .columns = 24, .rows = 12 };
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 1), ui.records.items[0].lines.len);
    try std.testing.expectEqual(@as(usize, 23), ui.records.items[0].columns);
    try std.testing.expect(@import("text.zig").styledWidth(ui.records.items[0].lines[0]) <= 23);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[0].output);
    ui.resize(.{ .columns = 12, .rows = 12 });
    ui.clock_ms = 80;
    ui.animate();
    try std.testing.expect(ui.resize_waiting and !ui.drawReady() and ui.frame.len == 0);
    fixture.pending = .{ .id = background_status.Id.from("other"), .command = background_status.Command.from("另一个😀长任务名称"), .result = .canceled, .duration_ms = 9 };
    ui.pollBackgroundCompletion();
    try std.testing.expectEqual(@as(usize, 2), fixture.takes);
    try std.testing.expectEqual(NoticeLevel.warning, ui.records.items[1].notice_level);
    try ui.draw();
    const second = &ui.records.items[1];
    try std.testing.expect(second.single_row);
    try std.testing.expectEqual(@as(usize, 1), second.lines.len);
    try std.testing.expectEqual(@as(usize, 11), second.columns);
    try std.testing.expect(@import("text.zig").styledWidth(second.lines[0]) <= 11);
    try std.testing.expect(std.unicode.utf8ValidateSlice(second.lines[0]));
    testAcknowledgeFullFrame(&ui);
}
test "memory active and queued own the neutral footer and terminals stay in conversation" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime: r.Runtime = undefined;
    var state = ui.connection.current();
    state.runtime = &runtime;
    // One braille frame, no phase word: the two states share one neutral row.
    state.memory = .{ .enabled = true, .active = .{ .id = 1, .phase = .extracting } };
    ui.clock_ms = 0;
    const frame0 = try std.fmt.allocPrint(arena.allocator(), "M: {s}", .{activity.spinner(0)});
    try std.testing.expectEqualStrings(frame0, try ui.hint(arena.allocator(), state));
    // queued only, active kept: the count is exactly the waiting jobs.
    state.memory.queued_count = 2;
    const with_queue = try std.fmt.allocPrint(arena.allocator(), "M: {s} +2", .{activity.spinner(0)});
    try std.testing.expectEqualStrings(with_queue, try ui.hint(arena.allocator(), state));
    // Waiting work alone still animates, with the same count.
    state.memory.active = null;
    try std.testing.expectEqualStrings(with_queue, try ui.hint(arena.allocator(), state));
    // A zero count never prints a number and no history comes from last_terminal.
    state.memory.queued_count = 0;
    state.memory.last_terminal = .{ .id = 1, .result = .saved, .saved_count = 2 };
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), state));
    // Disabled Memory owns nothing even with active/queued values present.
    state.memory = .{ .enabled = false, .active = .{ .id = 1, .phase = .saving }, .queued_count = 3 };
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), state));
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);

    var saved: memory_status.Terminal = .{ .id = 7, .result = .saved, .saved_count = 2 };
    saved.summary.append("偏好中文\n下一行\x1b]unsafe\x07");
    try ui.acceptMemoryCompletion(saved);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    const saved_row = ui.records.items[0];
    try std.testing.expectEqual(NoticeLevel.success, saved_row.notice_level);
    try std.testing.expect(saved_row.single_row);
    const expected_saved = try std.fmt.allocPrint(arena.allocator(), "M: \u{2713} {s}", .{saved.summary.text()});
    try std.testing.expectEqualStrings(expected_saved, saved_row.body.items);
    // The saved confirmation never advertises a count or a background run.
    try std.testing.expect(std.mem.find(u8, saved_row.body.items, "saved") == null);
    try std.testing.expect(std.mem.find(u8, saved_row.body.items, "(2)") == null);
    try std.testing.expect(std.mem.find(u8, saved_row.body.items, "偏好中文 下一行") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, saved_row.body.items, '\x1b') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, saved_row.body.items, '\n') == null);
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), state));

    for ([_]memory_status.Terminal{
        .{ .id = 8, .result = .failed, .failure = .storage },
        .{ .id = 9, .result = .uncertain, .failure = .unavailable },
    }) |terminal| {
        try ui.acceptMemoryCompletion(terminal);
        const row = ui.records.items[ui.records.items.len - 1];
        // Real outcomes stay real, keep the red failure tone, and are never
        // forced into the success shape or the one-row clipping.
        try std.testing.expectEqual(NoticeLevel.failure, row.notice_level);
        try std.testing.expect(!row.single_row);
        try std.testing.expect(std.mem.startsWith(u8, row.body.items, "M: "));
        try std.testing.expect(std.mem.count(u8, row.body.items, "\u{2713}") == 0);
    }
    try ui.acceptMemoryCompletion(.{ .id = 10, .result = .failed, .failure = .cleanup });
    try std.testing.expectEqual(NoticeLevel.failure, ui.records.items[ui.records.items.len - 1].notice_level);
    // A partial save followed by a failure is reported as a failure.
    try ui.acceptMemoryCompletion(.{ .id = 13, .result = .failed, .failure = .storage, .saved_count = 1 });
    const partial = ui.records.items[ui.records.items.len - 1];
    try std.testing.expectEqual(NoticeLevel.failure, partial.notice_level);
    try std.testing.expect(!partial.single_row);
    try std.testing.expect(std.mem.count(u8, partial.body.items, "\u{2713}") == 0);
    try ui.acceptMemoryCompletion(.{ .id = 11, .result = .canceled, .failure = .canceled });
    try std.testing.expectEqual(NoticeLevel.plain, ui.records.items[ui.records.items.len - 1].notice_level);
    const before_skipped = ui.records.items.len;
    try ui.acceptMemoryCompletion(.{ .id = 12, .result = .skipped });
    try std.testing.expectEqual(before_skipped, ui.records.items.len);
}
test "memory footer keeps rotating while only memory is active" {
    const Fixture = struct {
        active: bool = true,
        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .runtime = null, .available = true, .model = "fixture", .base_url = "", .memory = if (self.active)
                .{ .enabled = true, .active = .{ .id = 1, .phase = .saving } }
            else
                .{} };
        }
    };
    var fixture: Fixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.context = &fixture;
    ui.connection.current_fn = Fixture.current;
    try std.testing.expect(!ui.busy);
    // Two real ticks of the existing 80 ms clock each stage an ordinary dirty
    // draw; no timer, frame or refresh source is added for Memory.
    ui.clock_ms = 80;
    ui.dirty = false;
    ui.animate();
    try std.testing.expect(ui.dirty);
    const first = ui.animation_tick;
    try std.testing.expectEqual(@as(u64, 1), first);
    // Inside the same tick nothing is restaged.
    ui.dirty = false;
    ui.clock_ms = 159;
    ui.animate();
    try std.testing.expect(!ui.dirty);
    ui.clock_ms = 160;
    ui.animate();
    try std.testing.expect(ui.dirty);
    try std.testing.expectEqual(first + 1, ui.animation_tick);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const state = ui.connection.current();
    const tick0 = try std.fmt.allocPrint(arena.allocator(), "M: {s}", .{activity.spinner(0)});
    ui.clock_ms = 0;
    try std.testing.expectEqualStrings(tick0, try ui.hint(arena.allocator(), state));
    const tick80 = try std.fmt.allocPrint(arena.allocator(), "M: {s}", .{activity.spinner(80)});
    ui.clock_ms = 80;
    try std.testing.expectEqualStrings(tick80, try ui.hint(arena.allocator(), state));
    try std.testing.expect(!std.mem.eql(u8, tick0, tick80));
    // Nothing to animate once the owner reports no active/queued work.
    fixture.active = false;
    ui.dirty = false;
    ui.clock_ms = 160;
    ui.animate();
    try std.testing.expect(!ui.dirty);
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), ui.connection.current()));
}
test "paused follow-up preview keeps idle memory animation ticking without hidden overlay redraws" {
    const Fixture = struct {
        fn current(_: *anyopaque) Connection.State {
            return .{ .runtime = null, .available = true, .model = "fixture", .base_url = "", .memory = .{ .enabled = true, .active = .{ .id = 1, .phase = .saving } } };
        }
    };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.current_fn = Fixture.current;
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "queued input");
    ui.inbox.pause();
    try std.testing.expect(!ui.busy);
    try std.testing.expect(ui.queueSnapshot().paused);
    try std.testing.expectEqual(@as(usize, 1), ui.queueSnapshot().preview_count);
    for (1..3) |tick| {
        ui.dirty = false;
        ui.clock_ms = @intCast(tick * 80);
        ui.animate();
        try std.testing.expect(ui.dirty);
        try std.testing.expectEqual(@as(u64, @intCast(tick)), ui.animation_tick);
    }
    // A higher-priority footer hides Memory; animation must not repaint it.
    ui.secret_mode = true;
    ui.dirty = false;
    ui.clock_ms = 240;
    ui.animate();
    try std.testing.expect(!ui.dirty);
    ui.secret_mode = false;
    ui.settings_open = true;
    ui.clock_ms = 320;
    ui.animate();
    try std.testing.expect(!ui.dirty);
    ui.settings_open = false;
    // Passive resize still waits for real input/content and preserves dirty.
    ui.resize_waiting = true;
    ui.clock_ms = 400;
    ui.animate();
    try std.testing.expect(!ui.dirty);
    ui.dirty = true;
    ui.clock_ms = 480;
    ui.animate();
    try std.testing.expect(ui.dirty);
}
test "paused preview animates background alone on two ticks" {
    const Fixture = struct {
        fn current(_: *anyopaque) Connection.State {
            return .{ .runtime = null, .available = true, .model = "fixture", .base_url = "", .background = .{ .active_count = 1 } };
        }
    };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.current_fn = Fixture.current;
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "queued input");
    ui.inbox.pause();
    try std.testing.expect(ui.queueSnapshot().paused and ui.queueSnapshot().preview_count == 1);
    try std.testing.expect(!ui.busy and ui.active_tool == null and !ui.memoryAnimating());
    for (1..3) |tick| {
        ui.clock_ms = @intCast(tick * 80);
        ui.dirty = false;
        ui.animate();
        try std.testing.expect(ui.dirty);
        try std.testing.expectEqual(@as(u64, @intCast(tick)), ui.animation_tick);
        ui.dirty = false;
        ui.animate();
        try std.testing.expect(!ui.dirty);
    }
    ui.secret_mode = true;
    ui.clock_ms = 240;
    ui.animate();
    try std.testing.expect(!ui.dirty);
    ui.secret_mode = false;
    ui.settings_open = true;
    ui.clock_ms = 320;
    ui.animate();
    try std.testing.expect(!ui.dirty);
    ui.settings_open = false;
    ui.resize_waiting = true;
    ui.clock_ms = 400;
    ui.animate();
    try std.testing.expect(!ui.dirty);
    ui.dirty = true;
    ui.clock_ms = 480;
    ui.animate();
    try std.testing.expect(ui.dirty);
}
test "memory saved notice is one clipped physical row at the real width" {
    const fixture_text = "M: \u{2713} 已保存偏好：中文与emoji \u{1F600} 混排的长摘要不会换行";
    const Geometry = struct {
        fn check(record: *Record, columns: usize) !void {
            const text_module = @import("text.zig");
            try record.layout(std.testing.allocator, columns);
            try std.testing.expectEqual(@as(usize, 1), record.lines.len);
            const line = record.lines[0];
            try std.testing.expectEqual(columns, record.columns);
            try std.testing.expect(text_module.styledWidth(line) <= columns);
            try std.testing.expect(std.mem.startsWith(u8, line, theme.reset));
            // Whole clusters only: clipping never leaves a broken UTF-8 tail.
            try std.testing.expect(std.unicode.utf8ValidateSlice(line));
        }
    };
    var record = Record{ .kind = .notice, .single_row = true, .notice_level = .plain };
    defer record.deinit(std.testing.allocator);
    try record.body.appendSlice(std.testing.allocator, fixture_text);
    try Geometry.check(&record, 40);
    try std.testing.expect(std.mem.find(u8, record.lines[0], "...") != null);
    // The retained body, not a pre-cut copy, is what a new width re-derives.
    const wide = try std.testing.allocator.dupe(u8, record.lines[0]);
    defer std.testing.allocator.free(wide);
    try Geometry.check(&record, 12);
    try std.testing.expect(!std.mem.eql(u8, wide, record.lines[0]));
    // A width that fits nothing still stays inside one row without overrun.
    try Geometry.check(&record, 1);
    // Warning and failure rows keep their original tone when they opt in.
    record.notice_level = .warning;
    try Geometry.check(&record, 20);
    try std.testing.expect(std.mem.find(u8, record.lines[0], theme.caution) != null);
}
test "memory saved notices stay one row across a passive resize and new delivery" {
    const Fixture = struct {
        next: ?memory_status.Terminal = null,
        fn current(_: *anyopaque) Connection.State {
            return .{ .runtime = null, .available = true, .model = "fixture", .base_url = "", .memory = .{ .enabled = true, .active = .{ .id = 7, .phase = .saving } } };
        }
        fn take(raw: *anyopaque) ?memory_status.Terminal {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const value = self.next;
            self.next = null;
            return value;
        }
    };
    var fixture: Fixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.context = &fixture;
    ui.connection.current_fn = Fixture.current;
    ui.connection.take_memory_completion_fn = Fixture.take;
    ui.size = .{ .columns = 24, .rows = 12 };
    var saved: memory_status.Terminal = .{ .id = 5, .result = .saved };
    saved.summary.append("first-long-summary 中文与emoji \u{1F600} 超出可见列宽");
    fixture.next = saved;
    ui.pollMemoryCompletion();
    const first_id = ui.records.items[0].id;
    const text_module = @import("text.zig");
    var first_screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 24, .rows = 12 };
    try ui.draw();
    const first = &ui.records.items[ui.record_index.get(first_id).?];
    try std.testing.expect(first.single_row);
    try std.testing.expectEqual(@as(usize, 1), first.lines.len);
    try std.testing.expectEqual(@as(usize, 23), first.columns);
    try std.testing.expect(text_module.styledWidth(first.lines[0]) <= 23);
    try std.testing.expect(std.mem.find(u8, first.lines[0], "...") != null);
    try first_screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 1), first_screen.count("M: ~ first"));
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[ui.record_index.get(first_id).?].output);
    try std.testing.expect(ui.records.items[ui.record_index.get(first_id).?].delivery_complete);
    const before = ui.records.items.len;

    ui.resize(.{ .columns = 12, .rows = 12 });
    try std.testing.expect(ui.resize_waiting);
    ui.clock_ms = 80;
    ui.animate();
    try std.testing.expect(ui.resize_waiting);
    try std.testing.expect(!ui.drawReady());
    try std.testing.expectEqual(@as(usize, 0), ui.frame.len);
    try std.testing.expectEqual(before, ui.records.items.len);

    var next: memory_status.Terminal = .{ .id = 6, .result = .saved };
    next.summary.append("second-long-summary 中文与emoji \u{1F600} 超出可见列宽");
    fixture.next = next;
    ui.pollMemoryCompletion();
    try std.testing.expect(!ui.resize_waiting);
    try std.testing.expectEqual(before + 1, ui.records.items.len);
    const second_id = ui.records.items[ui.records.items.len - 1].id;
    try std.testing.expect(first_id != second_id);
    try ui.draw();
    const second = &ui.records.items[ui.record_index.get(second_id).?];
    try std.testing.expect(second.single_row);
    try std.testing.expectEqual(@as(usize, 1), second.lines.len);
    try std.testing.expectEqual(@as(usize, 11), second.columns);
    try std.testing.expect(text_module.styledWidth(second.lines[0]) <= 11);
    try std.testing.expect(std.mem.find(u8, second.lines[0], "...") != null);
    // The screen fixture cannot emulate terminal reflow: inspect each geometry
    // separately, and assert the new frame never replays the retired first row.
    try std.testing.expect(std.mem.find(u8, ui.frame, "first-long") == null);
    var second_screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 12, .rows = 12 };
    try second_screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 1), second_screen.count("M: ~ sec"));
    try std.testing.expectEqual(@as(usize, 0), second_screen.count("first"));
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[ui.record_index.get(second_id).?].output);
    try std.testing.expect(ui.records.items[ui.record_index.get(second_id).?].delivery_complete);
}
test "memory completion delivery is per delivered value and never clears a foreground error" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.notice = "Foreground error";
    // A real second delivery is a second notification even when the owner reuses
    // a job id; only the source queue/delivery layer proves one delivery.
    try ui.acceptMemoryCompletion(.{ .id = 0, .result = .failed, .failure = .storage });
    try ui.acceptMemoryCompletion(.{ .id = 0, .result = .failed, .failure = .storage });
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqualStrings("Foreground error", ui.notice);

    const Probe = struct {
        value: ?memory_status.Terminal,
        fn take(raw: *anyopaque) ?memory_status.Terminal {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const value = self.value;
            self.value = null;
            return value;
        }
    };
    var probe = Probe{ .value = .{ .id = 21, .result = .saved, .saved_count = 1 } };
    ui.connection.context = &probe;
    ui.connection.take_memory_completion_fn = Probe.take;
    ui.pollMemoryCompletion();
    try std.testing.expectEqual(@as(usize, 3), ui.records.items.len);
    // A repeated poll with no queued value publishes no duplicate.
    ui.pollMemoryCompletion();
    try std.testing.expectEqual(@as(usize, 3), ui.records.items.len);
    // A value already popped but not yet displayable retries without taking
    // another value and without touching the foreground error.
    ui.memory_completion_pending = .{ .id = 22, .result = .uncertain, .failure = .unavailable };
    ui.pollMemoryCompletion();
    try std.testing.expectEqual(@as(usize, 4), ui.records.items.len);
    try std.testing.expect(ui.memory_completion_pending == null);
    try std.testing.expectEqualStrings("Foreground error", ui.notice);
}
test "notice body OOM publishes no partial record and preserves foreground notice" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.notice = "foreground marker";
    const seed = "seed notice";
    try ui.appendNotice(.plain, seed);
    try ui.reserveRecord(); // Warm both containers for the next publication.
    const before = ui.records.items.len;
    const seed_id = ui.records.items[0].id;
    const next_id = ui.next_record_id;
    const foreground = ui.notice;
    {
        const allocator = ui.allocator;
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        ui.allocator = failing.allocator();
        defer ui.allocator = allocator;
        try std.testing.expectError(error.OutOfMemory, ui.appendNotice(.warning, "new warning"));
    }
    try std.testing.expectEqual(before, ui.records.items.len);
    try std.testing.expectEqual(before, ui.record_index.count());
    try std.testing.expectEqual(next_id, ui.next_record_id);
    try std.testing.expectEqual(seed_id, ui.records.items[0].id);
    try std.testing.expectEqual(@as(usize, 0), ui.record_index.get(seed_id).?);
    try std.testing.expectEqual(Kind.notice, ui.records.items[0].kind);
    try std.testing.expectEqual(NoticeLevel.plain, ui.records.items[0].notice_level);
    try std.testing.expectEqualStrings(seed, ui.records.items[0].body.items);
    try std.testing.expectEqualStrings(foreground, ui.notice);
    try ui.appendNotice(.warning, "new warning");
    try std.testing.expectEqual(before + 1, ui.records.items.len);
    try std.testing.expectEqual(NoticeLevel.warning, ui.records.items[before].notice_level);
    try std.testing.expectEqualStrings("new warning", ui.records.items[before].body.items);
    try std.testing.expectEqualStrings(foreground, ui.notice);
}
test "local memory OOM keeps one pending value then clears and takes the next" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const Probe = struct {
        value: ?memory_status.Terminal,
        fn take(raw: *anyopaque) ?memory_status.Terminal {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const value = self.value;
            self.value = null;
            return value;
        }
    };
    var probe = Probe{ .value = .{ .id = 31, .result = .saved, .saved_count = 1 } };
    ui.connection.context = &probe;
    ui.connection.take_memory_completion_fn = Probe.take;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    ui.allocator = failing.allocator();
    ui.memory_completion_pending = .{ .id = 30, .result = .failed, .failure = .storage };
    ui.pollMemoryCompletion();
    try std.testing.expect(ui.memory_completion_pending != null);
    // The source value is not consumed while the fixed pending slot is stuck.
    try std.testing.expect(probe.value != null);
    ui.allocator = std.testing.allocator;
    ui.pollMemoryCompletion();
    try std.testing.expect(ui.memory_completion_pending == null);
    try std.testing.expect(probe.value == null);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqual(NoticeLevel.failure, ui.records.items[0].notice_level);
    try std.testing.expectEqual(NoticeLevel.success, ui.records.items[1].notice_level);
}
test "remote memory notice binds a record receipt and skipped binds metadata" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.applyEvent(.{ .memory_completed = .{ .id = 41, .result = .saved, .saved_count = 2 } }, false, true);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    const receipt = ui.delivery_receipt.?;
    try std.testing.expectEqual(ui.records.items[0].id, receipt.id);
    try std.testing.expect(!receipt.source);
    ui.delivery_receipt = null;
    try ui.applyEvent(.{ .memory_completed = .{ .id = 42, .result = .skipped } }, false, true);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_receipt.?.id);
    try std.testing.expect(!ui.delivery_receipt.?.source);
}
test "complete publishes a failed terminal once and keeps it out of the footer" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.prompt = try std.testing.allocator.dupe(u8, "fixture");
    ui.job = .{ .runtime = undefined, .cancel = &cancel, .prompt = ui.prompt.? };
    ui.busy = true;
    ui.job.terminal = .{ .status = .failed, .detail = error.ModelRequestFailed };
    ui.job.done.store(true, .release);
    try ui.complete();
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(NoticeLevel.failure, ui.records.items[0].notice_level);
    try std.testing.expectEqualStrings("Failed", ui.notice);
    try std.testing.expect(std.mem.find(u8, ui.records.items[0].body.items, "Failed") != null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const hint = try ui.hint(arena.allocator(), ui.connection.current());
    try std.testing.expectEqualStrings("Not configured: /login, then /model", hint);
    try std.testing.expect(std.mem.find(u8, hint, "Failed") == null);
    // A different genuine notice is not swallowed by the terminal alias.
    ui.notice = "Foreground action failed";
    ui.observeAdvisories();
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqualStrings("Foreground action failed", ui.records.items[1].body.items);
    try std.testing.expectEqual(NoticeLevel.warning, ui.records.items[1].notice_level);
    try std.testing.expectEqualStrings("Not configured: /login, then /model", try ui.hint(arena.allocator(), ui.connection.current()));
}
test "settings and log advisories publish on change and again after recurrence" {
    const Fixture = struct {
        runtime: r.Runtime = undefined,
        settings_error: ?anyerror = null,
        log_error: ?anyerror = null,
        fn current(raw: *anyopaque) Connection.State {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return .{ .runtime = &self.runtime, .model = "fixture", .base_url = "http://unused.invalid", .settings_error = self.settings_error, .log_error = self.log_error };
        }
    };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = Fixture{};
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.context = &fixture;
    ui.connection.current_fn = Fixture.current;
    fixture.settings_error = error.TestSettingsFailure;
    fixture.log_error = error.TestLogFailure;
    ui.observeAdvisories();
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    ui.observeAdvisories();
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    fixture.settings_error = null;
    fixture.log_error = null;
    ui.observeAdvisories();
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    fixture.settings_error = error.TestSettingsFailure;
    fixture.log_error = error.TestLogFailure;
    ui.observeAdvisories();
    try std.testing.expectEqual(@as(usize, 4), ui.records.items.len);
    for (ui.records.items) |record| try std.testing.expectEqual(NoticeLevel.warning, record.notice_level);
}
test "one-shot rejections publish once and stay out of the hint" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const state = ui.connection.current();

    for ([_][]const u8{
        "Control queue full; input kept",
        "Queue resume requires idle, fresh input",
        "Metadata refresh requires an idle, non-pasted session",
        "Metadata refresh unavailable",
        "Empty or invalid key; Esc cancels",
    }) |message| {
        ui.notice = message;
        try std.testing.expect(!ui.persistentNotice(message));
        try std.testing.expect(std.mem.find(u8, try ui.hint(arena.allocator(), state), message) == null);
        const before = ui.records.items.len;
        ui.observeAdvisories();
        try std.testing.expectEqual(before + 1, ui.records.items.len);
        const record = ui.records.items[before];
        try std.testing.expectEqual(Kind.notice, record.kind);
        try std.testing.expectEqual(NoticeLevel.warning, record.notice_level);
        try std.testing.expectEqualStrings(message, record.body.items);
        try std.testing.expect(std.mem.find(u8, try ui.hint(arena.allocator(), state), message) == null);
        ui.observeAdvisories();
        try std.testing.expectEqual(before + 1, ui.records.items.len);
    }

    ui.openSettingsMenu();
    ui.openSettingsValue(.command_timeout_ms, state);
    const title = Ui.settingsValueTitle(.command_timeout_ms);
    try std.testing.expectEqualStrings(title, ui.notice);
    try std.testing.expect(ui.persistentNotice(title));
    const before = ui.records.items.len;
    ui.observeAdvisories();
    ui.observeAdvisories();
    try std.testing.expectEqual(before, ui.records.items.len);
    try std.testing.expectEqualStrings(title, try ui.hint(arena.allocator(), state));
}
test "async failure severity follows purpose and available configuration" {
    const FixtureState = struct {
        available: bool = false,

        fn current(raw: *anyopaque) Connection.State {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            return .{ .runtime = null, .available = self.available, .model = "fixture", .base_url = "" };
        }
    };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = FixtureState{};
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection.context = &fixture;
    ui.connection.current_fn = FixtureState.current;

    for ([_]bool{ false, true }) |available| {
        fixture.available = available;
        try std.testing.expectEqual(NoticeLevel.failure, ui.asyncFailureLevel(.submit));
        try std.testing.expectEqual(if (available) NoticeLevel.warning else NoticeLevel.failure, ui.asyncFailureLevel(.configure));
        for ([_]AsyncPurpose{ .preference, .enqueue, .model, .effort, .refresh, .cancel }) |purpose| {
            try std.testing.expectEqual(NoticeLevel.warning, ui.asyncFailureLevel(purpose));
        }
    }
}
test "notice severity colors conversation rows and never reaches the neutral footer" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.appendNotice(.plain, "plain-result");
    try ui.appendNotice(.warning, "warning-result");
    try ui.appendNotice(.failure, "failure-result");
    for (ui.records.items, 0..) |*record, index| {
        try record.layout(std.testing.allocator, 80);
        for (record.lines) |line| try std.testing.expect(std.mem.endsWith(u8, line, theme.reset));
        try std.testing.expectEqual(@as(usize, 1), record.lines.len);
        _ = index;
    }
    try std.testing.expect(std.mem.find(u8, ui.records.items[1].lines[0], "\x1b[38;5;220mwarning-result") != null);
    try std.testing.expect(std.mem.find(u8, ui.records.items[2].lines[0], theme.failure ++ "failure-result") != null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(std.mem.indexOfScalar(u8, try ui.footerHint(arena.allocator(), ui.connection.current()), '\x1b') == null);
}
test "wrapped composer cursor is ACK owned across sparse redraws" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 30, .rows = 12 };
    const raw = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKL";
    _ = try ui.editor.insert(raw);
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 30, .rows = 12 };
    try ui.draw();
    try std.testing.expect(ui.frame_composer_rows > 1 and ui.frame_composer_rows <= composer_layout.max_rows);
    try std.testing.expectEqualStrings(raw, ui.editor.bytes.items);
    try screen.replay(ui.frame);
    // The composer occupies the tail; the notice sits directly above it and no
    // blank screen rows are written below the last composer row.
    try std.testing.expectEqual(ui.frame_composer_rows + 1, ui.frame_height);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
    const rows = ui.tail_composer_rows;
    ui.editor.cursor = 0;
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 0), ui.tail_cursor_rows_up);
    try std.testing.expect(ui.frame_cursor_rows_up > 0);
    try screen.replay(ui.frame);
    const up = ui.frame_cursor_rows_up;
    try std.testing.expectEqual(screen.rows - 1 - up, screen.row);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(up, ui.tail_cursor_rows_up);
    try std.testing.expectEqual(rows, ui.tail_composer_rows);
    ui.editor.cursor = ui.editor.bytes.items.len;
    try ui.draw();
    try std.testing.expect(ui.frame_sparse);
    try screen.replay(ui.frame);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    try std.testing.expectEqual(@as(usize, 1), screen.count("(fixture)"));
    try std.testing.expectEqualStrings(raw, ui.editor.bytes.items);
    testAcknowledgeFullFrame(&ui);
}
test "closing approval reuses its footprint without erasing a multiline composer" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 30, .rows = 16 };
    _ = try ui.editor.insert("AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH");
    ui.editor.cursor = 0;
    ui.permission = .{ .id = 7, .description = try std.testing.allocator.dupe(u8, "approval one\napproval two\napproval three"), .clipped = false };
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 30, .rows = 16 };
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const before = ui.tail_height;
    try std.testing.expect(before > 4);
    ui.clearPermission();
    try ui.draw();
    const after = ui.frame_height;
    try std.testing.expectEqual(before, after); // Reused owned rows keep the footer anchored.
    try std.testing.expect(ui.frame_composer_rows > 1);
    try std.testing.expect(ui.frame_cursor_rows_up > 0); // cursor on the first composer line
    const suffix = ui.frame_tail_snapshot.?.cursor_suffix;
    try std.testing.expect(std.mem.indexOfScalar(u8, suffix, '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, suffix, "\x1b[M") == null);
    try screen.replay(ui.frame);
    // Every prepared composer row survives; cleaning from the already-moved-up
    // cursor row would have erased the lower two. The HHHH marker wraps across
    // two rows, so compare each actual visible suffix and the whole raw text.
    var composer_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer composer_arena.deinit();
    const prepared = try ui.prepareComposer(composer_arena.allocator(), ui.connection.current(), ui.size.columns -| 1);
    try std.testing.expectEqual(ui.frame_composer_rows, prepared.layout.lines.len);
    const decoration_width = text.width(prepared.decoration.plain);
    const first_row = screen.row - prepared.layout.cursor_row;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(std.testing.allocator);
    for (prepared.layout.lines, 0..) |line, index| {
        const visible = std.mem.trimEnd(u8, screen.grid[first_row + index][decoration_width..], " ");
        try std.testing.expectEqualStrings(line, visible);
        try joined.appendSlice(std.testing.allocator, visible);
    }
    try std.testing.expectEqualStrings(ui.editor.bytes.items, joined.items);
    try std.testing.expectEqual(screen.rows - 1 - ui.frame_cursor_rows_up, screen.row);
    testAcknowledgeFullFrame(&ui);
}
test "wrapped composer idle LF debt first obtains a single row fresh ACK" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 30, .rows = 12 };
    _ = try ui.editor.insert("abcdefghijklmnopqrstuvwxyz0123456789");
    ui.editor.cursor = 0;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.tail_composer_rows > 1 and ui.tail_cursor_rows_up > 0);
    ui.editor.clear();
    try Ui.key(&ui, .enter);
    try std.testing.expectEqual(@as(u16, 1), ui.idle_breaks);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 0), ui.frame_idle_breaks);
    try std.testing.expectEqual(@as(usize, 1), ui.frame_composer_rows);
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    try std.testing.expectEqual(@as(u16, 1), ui.frame_idle_breaks);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(u16, 0), ui.idle_breaks);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
}
test "memory terminal is conversation-only and never replaces foreground errors" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var runtime: r.Runtime = undefined;
    var state = ui.connection.current();
    state.runtime = &runtime;
    state.memory = .{ .enabled = true, .last_terminal = .{ .id = 1, .result = .uncertain } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    ui.clock_ms = 100;
    // Historical terminal state is never replayed into the footer.
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), state));
    ui.notice = "Foreground error";
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), state));
    ui.notice = "Ready";
    ui.clock_ms = 999_999;
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), state));
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try ui.acceptMemoryCompletion(.{ .id = 2, .result = .uncertain, .failure = .unavailable });
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(NoticeLevel.failure, ui.records.items[0].notice_level);
    try std.testing.expectEqualStrings("", try ui.hint(arena.allocator(), state));
    try std.testing.expect(ui.future == null and !ui.busy and ui.prompt == null);
    try std.testing.expect(ui.inbox.snapshot().newest_id == null);
}
test "authentication terminal detail is red in conversation and absent from the footer" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state = ui.connection.current();
    state.settings_notice = "Saved thinking level not applied: model capabilities unknown";
    ui.notice = "Failed";
    for ([_]u16{ 401, 403 }) |code| {
        const result: r.Terminal = .{ .status = .failed, .detail = error.ModelRequestFailed, .model_failure = .authentication, .http_status = code };
        ui.last_terminal = result;
        ui.queueTerminalNotice(result);
        const record = ui.records.items[ui.records.items.len - 1];
        try std.testing.expectEqual(NoticeLevel.failure, record.notice_level);
        try std.testing.expect(std.mem.startsWith(u8, record.body.items, if (code == 401) "Failed [HTTP 401]" else "Failed [HTTP 403]"));
        try std.testing.expect(std.mem.find(u8, record.body.items, "authentication") != null);
        const hint = try ui.hint(arena.allocator(), state);
        try std.testing.expect(std.mem.find(u8, hint, "HTTP") == null);
        try std.testing.expect(std.mem.find(u8, hint, "authentication") == null);
        try std.testing.expect(std.mem.find(u8, hint, "Saved thinking level") != null);
        ui.removeRecord(ui.records.items.len - 1);
    }
    // Storage faults are not aggregated into this neutral footer.
    state.settings_error = error.TestSettingsFailure;
    try std.testing.expect(std.mem.find(u8, try ui.hint(arena.allocator(), state), "SETTINGS FAILED") == null);
    state.settings_error = null;
    ui.last_terminal = null;
    ui.notice = "Ready";
    try std.testing.expect(std.mem.find(u8, try ui.hint(arena.allocator(), state), "Saved thinking level") != null);
}
test "provider auth Go fresh Enter after pasted key restores ordinary drawn composer" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/login\r", sink);
    try std.testing.expect(ui.provider_open and !ui.secret_mode);
    try ui.parser.feed("\x1b[B\x1b[B\x1b[B\r", sink);
    try std.testing.expect(!ui.secret_mode); // No unseen selection authority.
    try ui.draw();
    for ([_][]const u8{ "DeepSeek", "OpenCode Zen", ">   OpenCode Go", "Provider> " }) |label| try std.testing.expect(std.mem.find(u8, ui.frame, label) != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.secret_mode and !ui.provider_open);
    try std.testing.expectEqual(core_config.providers.Id.opencode_go, ui.secret_provider.?);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.parser.feed("\x1b[200~fake-ui-key\x1b[201~\r", sink);
    try std.testing.expect(ui.secret_mode and ui.secret.failed and fixture.provider_saves == 0);
    try ui.parser.feed("\x15", sink);
    try ui.parser.feed("\x1b[200~fake-ui-key\x1b[201~", sink);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(std.mem.startsWith(u8, &screen.grid[screen.row], "API key> ***********"));
    try std.testing.expect(std.mem.find(u8, ui.frame, "API key for OpenCode Go") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "https://opencode.ai/zen/go/v1") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "fake-ui-key") == null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\rsame-read-secret-tail", sink);
    try std.testing.expect(!ui.secret_mode and !ui.secret_quarantine and !ui.parser.secret and ui.secret_provider == null and ui.secret.len == 0);
    try std.testing.expect(ui.parser.stop_feed and !ui.parser.secret_paste and !ui.parser.secret_batch_paste);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    for (ui.secret.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (ui.parser.escape) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (ui.parser.utf8) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try ui.draw();
    for ([_][]const u8{ "API key", "***", "fake-ui-key", "same-read-secret-tail" }) |hidden| {
        try std.testing.expect(std.mem.find(u8, ui.frame, hidden) == null);
    }
    try screen.replay(ui.frame);
    for ([_][]const u8{ "API key", "***", "fake-ui-key", "same-read-secret-tail" }) |hidden| try std.testing.expectEqual(@as(usize, 0), screen.count(hidden));
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("nexttext", sink);
    try std.testing.expectEqualStrings("nexttext", ui.editor.bytes.items);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(std.mem.find(u8, &screen.grid[screen.row], "nexttext") != null);
    try std.testing.expectEqual(@as(usize, 0), screen.count("same-read-secret-tail"));
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(fixture.key_matched and fixture.provider_saves == 1);
    try std.testing.expectEqual(core_config.providers.Id.opencode_go, fixture.saved_provider.?);
    try std.testing.expect(publishedNotice(&ui, "saved locally"));
    try std.testing.expectEqualStrings("Ready", ui.notice);
}
test "provider auth denies partial stale resize reopen and pasted choices" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/login\r", sink);
    try ui.draw();
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode);
    try ui.parser.feed("\x1b[B", sink);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    ui.resize(.{ .columns = 81, .rows = 24 });
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(!ui.provider_open);
    try ui.parser.feed("/login\r\r", sink);
    try std.testing.expect(ui.provider_open and !ui.secret_mode);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~fake-ui-key\x1b[201~\r", sink);
    try std.testing.expect(ui.provider_picker.pasted and !ui.secret_mode);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "fake-ui-key") == null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x15\r", sink);
    try std.testing.expect(!ui.secret_mode); // Clear requires a fresh frame too.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.secret_mode);
    try std.testing.expectEqual(@as(usize, 0), fixture.provider_saves);
}
test "provider auth requires a visible full label and save failure wipes the key" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture: SelectionFixture = .{ .provider_hint = .opencode_go, .configured_providers = 4, .fail = true };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/login\r", sink);
    try std.testing.expectEqual(core_config.providers.Id.all.len, ui.provider_choices.len);
    ui.size = .{ .columns = 12, .rows = 9 };
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!ui.secret_mode);
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "DeepSeek") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\rfake-ui-key\r", sink);
    // Entering secret mode deliberately discards the rest of that read.
    try std.testing.expect(ui.secret_mode and ui.secret.len == 0);
    try ui.parser.feed("fake-ui-key\r", sink);
    try std.testing.expect(!ui.secret_mode and ui.secret.len == 0 and ui.secret_provider == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.provider_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Could not save") != null);
}
test "first DeepSeek login initializes default and Shift Tab preserves budgets and atomic saves" {
    const Session = @import("../app/session.zig").Session;
    const metadata = @import("../app/model_metadata.zig");
    const Fetch = struct {
        fn official(a: std.mem.Allocator, _: Io, id: core_config.providers.Id, key: ?[]const u8) !metadata.Listing {
            try std.testing.expectEqual(core_config.providers.Id.deepseek, id);
            try std.testing.expectEqualStrings("fake-fresh-login", key.?);
            return metadata.parseListing(a,
                \\{"data":[{"id":"deepseek-flash","context_window":131072,"effort":{"supported_levels":["low","high","max"],"default_level":"high"}}]}
            , id);
        }
        fn public(_: std.mem.Allocator, _: Io) !metadata.Listing {
            return .{ .dev_done = true };
        }
    };
    try text.initLocale();
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const home = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", home);
    var session = try Session.initWithOptions(a, io, &env, home, .{}, .{ .auto_refresh_models = true });
    defer session.deinit();
    session.metadata_fetch = Fetch.official;
    session.metadata_dev_fetch = Fetch.public;
    try std.testing.expect(session.app == null);
    try session.connection().configure("fake-fresh-login");
    const before = session.app.?.config.value.model;
    try std.testing.expect(before.reasoning == null);
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(a, io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = session.connection();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expect(std.mem.find(u8, ui.notice, "are loading") != null);
    try std.testing.expect(session.app.?.config.value.model.reasoning == null);
    try std.testing.expect(session.metadata_job == null); // Shortcut itself never fetches.
    try std.testing.expect(session.connection().poll_models_fn.?(session.connection().context, true));
    const job = session.metadata_job.?;
    if (job.future) |*future| future.await(io);
    job.future = null;
    if (job.dev_future) |*future| future.await(io);
    job.dev_future = null;
    try std.testing.expect(session.connection().poll_models_fn.?(session.connection().context, true));
    // A fresh empty conversation initializes and persists off without cycling
    // or changing request budgets.
    try std.testing.expectEqual(@as(u8, 0x55), session.connection().current().effort_levels.mask);
    try std.testing.expectEqual(shared.ReasoningEffort.off, session.connection().current().reasoning_effort);
    try std.testing.expectEqual(shared.ReasoningEffort.off, shared.ReasoningEffort.fromName(session.global_config.?.value.registry.?.reasoning_effort.?));
    const off_wire = r.withReasoning(session.app.?.config.value, .{ .scope = .{ .connection = "https://api.deepseek.com", .model = "deepseek-flash", .protocol = .chat }, .system = "", .tools = &.{}, .messages = &.{} });
    try std.testing.expectEqual(@as(?[]const u8, null), off_wire.reasoning_effort);
    try std.testing.expectEqual(@as(?bool, false), off_wire.thinking);
    const saved_settings = try tmp.dir.readFileAlloc(io, ".thin/config.json", a, .limited(65536));
    defer a.free(saved_settings);
    try tmp.dir.writeFile(io, .{ .sub_path = ".thin/config.json", .data = "{}" });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Could not save") != null);
    try std.testing.expect(session.app.?.config.value.model.reasoning != null);
    try std.testing.expectEqual(shared.ReasoningEffort.off, session.connection().current().reasoning_effort);
    try tmp.dir.writeFile(io, .{ .sub_path = ".thin/config.json", .data = saved_settings });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expectEqual(shared.ReasoningEffort.low, session.connection().current().reasoning_effort);
    try std.testing.expectEqual(before.context_tokens, session.app.?.config.value.model.context_tokens);
    try std.testing.expectEqual(before.output_tokens, session.app.?.config.value.model.output_tokens);
    try std.testing.expectEqual(before.input_price_threshold, session.app.?.config.value.model.input_price_threshold);
    try std.testing.expectEqual(before.protocol, session.app.?.config.value.model.protocol);
    // The adopted map must be owned, not borrowed from movable cache storage.
    session.metadata_cache.deinit(a);
    session.metadata_cache = .{};
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(shared.ReasoningEffort.high, session.connection().current().reasoning_effort);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(shared.ReasoningEffort.max, session.connection().current().reasoning_effort);
    try std.testing.expectEqual(shared.ReasoningEffort.max, shared.ReasoningEffort.fromName(session.global_config.?.value.registry.?.reasoning_effort));
    const wire = r.withReasoning(session.app.?.config.value, .{ .scope = .{ .connection = "https://api.deepseek.com", .model = "deepseek-flash", .protocol = .chat }, .system = "", .tools = &.{}, .messages = &.{} });
    try std.testing.expectEqualStrings("max", wire.reasoning_effort.?);
    try std.testing.expect(wire.thinking.?);
    var disk = try session.store.loadExisting();
    defer core_config.release(&disk);
    try std.testing.expect(disk.value.registry.?.find("deepseek").?.patchFor("deepseek-flash").?.reasoning == null);
    try std.testing.expect(!session.app.?.journal.started);
}
test "effort confirmation expires after five seconds and repeated switches restart it" {
    var fixture: SelectionFixture = .{ .effort = .low, .levels = .{ .mask = 0x55 } };
    defer fixture.deinit();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(screen.visible("fixture-old) 3.1%"));
    try std.testing.expect(ui.effort_flash == null);

    ui.clock_ms = 1000;
    ui.cycleEffort(); // low -> high, expires at 6000.
    const context = ui.display.context;
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(screen.visible("fixture-old) high"));
    try std.testing.expectEqualDeep(context, ui.display.context);
    // The composer and its real notice occupy a short bottom tail.
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    try std.testing.expectEqual(@as(usize, 2), ui.frame_height);
    try std.testing.expectEqual(text.width("(fixture-old) high> "), screen.col);

    ui.clock_ms = 2500;
    ui.cycleEffort(); // high -> max, now expires at 7500 instead.
    ui.dirty = false;
    ui.clock_ms = 6000;
    ui.expireEffortFlash();
    try std.testing.expect(!ui.dirty);
    fixture.fail = true;
    ui.cycleEffort(); // Failed save neither changes the level nor extends time.
    try std.testing.expectEqual(@as(u64, 7500), ui.effort_flash.?.until_ms);
    try std.testing.expectEqual(shared.ReasoningEffort.max, ui.effort_flash.?.level);
    ui.clock_ms = 7499;
    ui.dirty = false;
    ui.expireEffortFlash();
    try std.testing.expect(!ui.dirty);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(screen.visible("fixture-old) max"));

    ui.display.context = .{ .tokens = 2000, .limit = fixture.limit };
    ui.clock_ms = 7500;
    ui.expireEffortFlash(); // Idle expiry schedules a redraw without a keypress.
    try std.testing.expect(ui.dirty and ui.effort_flash == null);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(screen.visible("fixture-old) 6.1%"));
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    ui.cycleEffort();
    try std.testing.expect(ui.effort_flash == null);
    fixture.fail = false;
    ui.cycleEffort();
    try ui.selectModel("fixture-next");
    try std.testing.expectEqual(fixture.effort, ui.effort_flash.?.level);
    try std.testing.expectEqual(@as(u64, 12500), ui.effort_flash.?.until_ms);
}
test "effort shortcut follows declared levels and unknown or singleton sets never publish" {
    var fixture: SelectionFixture = .{ .effort = .off, .levels = .{} };
    defer fixture.deinit();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 0), fixture.cycles);
    try std.testing.expectEqual(shared.ReasoningEffort.off, fixture.effort);
    try std.testing.expect(std.mem.find(u8, ui.notice, "capabilities unknown") != null);
    fixture.levels = .{ .mask = 1 };
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 0), fixture.cycles);
    fixture.levels = .{ .mask = 0x55 }; // off / low / high / max, not a six-level cycle.
    for ([_]shared.ReasoningEffort{ .low, .high, .max, .off }) |expected| {
        ui.cycleEffort();
        try std.testing.expectEqual(expected, fixture.effort);
    }
    try std.testing.expectEqual(@as(usize, 4), fixture.cycles);
    // An external connection may still supply an unspecified current value.
    // Its first shortcut chooses a supported level, not capabilities unknown.
    fixture.effort = .unspecified;
    ui.cycleEffort();
    try std.testing.expectEqual(shared.ReasoningEffort.off, fixture.effort);
    try std.testing.expectEqual(@as(usize, 5), fixture.cycles);
}
test "slash menu shows model login compact with arguments and descriptions but no shortcut hints" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.size = .{ .columns = 80, .rows = 24 };
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };

    // Typing `/` opens the menu without executing anything.
    try ui.parser.feed("/", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Commands") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/model") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Configure provider") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/model [exact-id|--refresh]  Select model") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/compact") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Compact conversation") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Type to filter; Tab complete") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Up/Down select; Enter run") == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    testAcknowledgeFullFrame(&ui);

    // Case-insensitive filtering keeps only the matching entry.
    try ui.parser.feed("LO", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "/login") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/model") == null);
    testAcknowledgeFullFrame(&ui);

    // Esc dismisses until the token changes again.
    try ui.parser.feed("\x1b", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(!ui.commandMenuVisible());
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Commands") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Configure provider") == null);
    // The independent setup hint remains; it is not a menu item.
    try std.testing.expect(std.mem.find(u8, ui.frame, "Not configured: /login") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("G", sink);
    try std.testing.expect(ui.commandMenuVisible());
    try ui.draw();
    testAcknowledgeFullFrame(&ui);

    // Enter runs the highlighted `/login`, which here means entering key entry.
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.secret_mode);
    try std.testing.expect(!ui.commandMenuVisible());
}
test "slash menu enter selects the highlighted model entry" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/", sink);
    // The first entry is `/model`, which opens the model picker rather than
    // switching directly, so the fixture records no selection yet.
    try std.testing.expectEqual(command_menu_module.Command.model, ui.command_menu.choice(ui.command_matches).?);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.model_picker == null);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.model_picker != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
}
test "slash menu Tab completes only an ACKed choice without executing while ordinary Tab indents" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/", sink);
    try ui.draw();
    // A partial frame cannot authorize even a text-only completion.
    ui.frame_offset = ui.frame.len / 2;
    try ui.parser.feed("\t", sink);
    try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\t", sink);
    try std.testing.expectEqualStrings("/model", ui.editor.bytes.items);
    try std.testing.expectEqual(ui.editor.bytes.items.len, ui.editor.cursor);
    try std.testing.expect(ui.model_picker == null and ui.commandMenuVisible());
    try std.testing.expect(!ui.busy and !ui.secret_mode and !ui.provider_open);
    try std.testing.expect(ui.displayed_command_generation == null);
    try ui.draw();
    try std.testing.expect(ui.commandMenuVisible());
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\t", sink); // Already complete: no spaces, cycling or action.
    try std.testing.expectEqualStrings("/model", ui.editor.bytes.items);
    try std.testing.expect(ui.model_picker == null and !ui.busy);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.model_picker != null);
    try ui.modelKey(.escape);
    try ui.parser.feed("\t", sink);
    try std.testing.expectEqualStrings("    ", ui.editor.bytes.items);
}
test "slash menu Tab canonicalizes filtered commands without opening surfaces or jobs" {
    for ([_]struct { prefix: []const u8, full: []const u8 }{
        .{ .prefix = "/mo", .full = "/model" },
        .{ .prefix = "/LG", .full = "/login" },
        .{ .prefix = "/cpt", .full = "/compact" },
        .{ .prefix = "/stg", .full = "/settings" },
    }) |case| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed(case.prefix, sink);
        try ui.parser.feed("\t", sink); // No visible ACK yet.
        try std.testing.expectEqualStrings(case.prefix, ui.editor.bytes.items);
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        try ui.parser.feed("\t", sink);
        try std.testing.expectEqualStrings(case.full, ui.editor.bytes.items);
        try std.testing.expectEqual(case.full.len, ui.editor.cursor);
        try std.testing.expect(!ui.busy and !ui.secret_mode and !ui.provider_open and ui.model_picker == null);
        try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    }
}
test "slash menu Tab honors highlighted selection only after a new ACK" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[B\t", sink);
    try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\t", sink);
    try std.testing.expectEqualStrings("/login", ui.editor.bytes.items);
    try std.testing.expect(!ui.secret_mode and !ui.provider_open and ui.model_picker == null and !ui.busy);
}
test "slash menu pasted Tab remains literal and never completes" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[200~/mo\t\x1b[201~", sink);
    try std.testing.expectEqualStrings("/mo\t", ui.editor.bytes.items);
    try std.testing.expect(!ui.commandMenuVisible() and !ui.busy and ui.model_picker == null);
}
test "slash menu rejects stale navigation generations and resize ABA" {
    for ([_]bool{ false, true }) |resize_case| {
        var cancel = p.Cancellation{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed("/", sink);
        try ui.draw();
        if (resize_case) {
            const original = ui.size;
            ui.resize(.{ .columns = original.columns - 1, .rows = original.rows });
            ui.resize(original);
        } else {
            // Same token/choice after clear must not inherit the earlier frame.
            try ui.parser.feed("\x15/", sink);
        }
        testAcknowledgeFullFrame(&ui);
        try ui.parser.feed("\t", sink);
        try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
        try ui.parser.feed("\r", sink);
        try std.testing.expect(ui.model_picker == null and !ui.secret_mode);
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        try ui.parser.feed("lg\t\r", sink);
        try std.testing.expect(!ui.secret_mode); // Changed token/selection is not yet shown.
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        try ui.parser.feed("\r", sink);
        try std.testing.expect(ui.secret_mode);
    }
}
test "popup close restores every visible transcript row for root provider and model menus" {
    try text.initLocale();
    for ([_]usize{ 2, 60 }) |history_length| {
        for ([_]terminal_module.Size{
            .{ .columns = 80, .rows = 24 }, .{ .columns = 16, .rows = 24 },
            .{ .columns = 16, .rows = 12 }, .{ .columns = 16, .rows = 7 },
            .{ .columns = 9, .rows = 7 },
        }) |dimensions| {
            for ([_][]const u8{ "/", "/login\r", "/model\r" }) |command| {
                var cancel = p.Cancellation{};
                var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
                defer bridge.deinit();
                var fixture = SelectionFixture{};
                defer fixture.deinit();
                var ui = fixtureUi(&bridge, &cancel);
                defer ui.deinit();
                ui.connection = fixture.connection();
                ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
                ui.size = dimensions;
                var history: std.ArrayList(u8) = .empty;
                defer history.deinit(std.testing.allocator);
                for (0..history_length) |i| {
                    const line = try std.fmt.allocPrint(std.testing.allocator, "{s}row-{d:0>3}", .{ if (i == 0) "" else "\n", i });
                    defer std.testing.allocator.free(line);
                    try history.appendSlice(std.testing.allocator, line);
                }
                _ = try ui.add(.assistant, history.items);
                var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = dimensions.columns, .rows = dimensions.rows };
                try ui.draw();
                const initial_height = ui.frame_height;
                const initial_above = ui.frame_menu_history.?.above.len;
                const initial_borrowed = ui.frame_menu_history.?.borrowed.len;
                try screen.replay(ui.frame);
                const initial_tail_start = (screen.row + ui.frame_cursor_rows_up + 1) -| initial_height;
                testAcknowledgeFullFrame(&ui);
                const before = screen.grid;
                const history_before = screen.history_len;
                const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
                try ui.parser.feed(command, sink);
                try ui.draw();
                const menu_height = ui.frame_height;
                const menu_borrow_count = ui.frame_borrow_rows;
                const menu_above = ui.frame_menu_history.?.above.len;
                const menu_borrowed = ui.frame_menu_history.?.borrowed.len;
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
                // Locate the actual first candidate, not merely missing labels.
                var first: ?usize = null;
                for (screen.grid, 0..) |line, i| {
                    if (std.mem.startsWith(u8, &line, "> ")) {
                        first = i;
                        break;
                    }
                }
                try std.testing.expect(first != null and first.? > 0);
                try std.testing.expectEqualStrings("", std.mem.trim(u8, &screen.grid[first.? - 1], " "));
                // Popup borrowing is reversible and must not scroll long history.
                try std.testing.expectEqual(history_before, screen.history_len);
                try ui.parser.feed("\x1b", sink);
                try ui.parser.expireEscape(sink);
                try ui.parser.feed("\x15", sink);
                try ui.draw();
                const close_height = ui.frame_height;
                const close_above = ui.frame_menu_history.?.above.len;
                const close_borrowed = ui.frame_menu_history.?.borrowed.len;
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                try std.testing.expectEqual(screen.rows - 1, screen.row + ui.tail_cursor_rows_up);
                for (before[0 .. dimensions.rows - 2], screen.grid[0 .. dimensions.rows - 2], 0..) |old, restored, row| {
                    if (!std.mem.eql(u8, &old, &restored)) {
                        std.debug.print("popup restore history={d} size={d}x{d} command={s} row={d}\ninitial height={d} tail_start={d} above={d} borrowed={d}; menu height={d} borrow_count={d} above={d} borrowed={d}; close height={d} above={d} borrowed={d}\n", .{
                            history_length,    dimensions.columns, dimensions.rows, std.mem.trimEnd(u8, command, "\r"), row,
                            initial_height,    initial_tail_start, initial_above,   initial_borrowed,                   menu_height,
                            menu_borrow_count, menu_above,         menu_borrowed,   close_height,                       close_above,
                            close_borrowed,
                        });
                    }
                    try std.testing.expectEqualStrings(&old, &restored);
                }
                try std.testing.expectEqual(history_before, screen.history_len);
                // A second ordinary frame must retain the repaired history too.
                try ui.draw();
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                for (before[0 .. dimensions.rows - 2], screen.grid[0 .. dimensions.rows - 2]) |old, restored|
                    try std.testing.expectEqualStrings(&old, &restored);
                if (history_length == 60) {
                    // Completed history belongs to native scrollback: PageUp is
                    // not a program preview and never regroups canonical records.
                    const browsing_before = screen.grid;
                    for (0..8) |_| try ui.parser.feed("\x1b[5~", sink);
                    try ui.draw();
                    try std.testing.expect(std.mem.find(u8, ui.frame, "row-0") == null);
                    try screen.replay(ui.frame);
                    testAcknowledgeFullFrame(&ui);
                    try std.testing.expectEqual(history_before, screen.history_len);
                    for (browsing_before[0 .. dimensions.rows - 2], screen.grid[0 .. dimensions.rows - 2]) |old, restored|
                        try std.testing.expectEqualStrings(&old, &restored);
                    for (0..8) |_| try ui.parser.feed("\x1b[6~", sink);
                    try ui.draw();
                    try std.testing.expect(std.mem.find(u8, ui.frame, "row-0") == null);
                    try screen.replay(ui.frame);
                    testAcknowledgeFullFrame(&ui);
                    for (browsing_before[0 .. dimensions.rows - 2], screen.grid[0 .. dimensions.rows - 2]) |old, restored|
                        try std.testing.expectEqualStrings(&old, &restored);
                    try std.testing.expectEqual(history_before, screen.history_len);
                }
                _ = try ui.add(.assistant, "new-row");
                try ui.draw();
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                // Releasing a repaired prefix for subsequent output must not
                // duplicate or lose ANY earlier line, including native history.
                for (0..history_length) |i| {
                    var marker: [16]u8 = undefined;
                    const value = try std.fmt.bufPrint(&marker, "row-{d:0>3}", .{i});
                    try std.testing.expectEqual(@as(usize, 1), screen.count(value));
                }
                try std.testing.expectEqual(@as(usize, 1), screen.count("new-row"));
                try ui.parser.feed(command, sink);
                try ui.draw();
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                // A width ABA revokes every physical coordinate. The next fresh
                // frame establishes a bottom anchor without reclaiming stale rows
                // or regenerating completed record text.
                ui.resize(.{ .columns = dimensions.columns - 1, .rows = dimensions.rows });
                ui.resize(dimensions);
                try std.testing.expect(ui.tail_snapshot == null and ui.abandon_tail and !ui.tail_bottom);
                // ABA back to the original size grants no autonomous repaint.
                ui.clock_ms += 5000;
                ui.resize(dimensions);
                ui.animate();
                try std.testing.expect(!ui.drawReady() and ui.frame.len == 0);
                ui.requestDraw(); // Genuine input, not a geometry repair.
                try ui.draw();
                try std.testing.expect(std.mem.find(u8, ui.frame[0..ui.frame_clear_end], "\x1b[999B") == null);
                try std.testing.expect(std.mem.find(u8, ui.frame[0..ui.frame_clear_end], "\x1b[2J") == null);
                try std.testing.expect(std.mem.find(u8, ui.frame[0..ui.frame_clear_end], "\x1b[0J") == null);
                try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r"));
                try std.testing.expect(std.mem.find(u8, ui.frame[0..ui.frame_clear_end], "\x1b[2J") == null);
                try std.testing.expect(std.mem.find(u8, ui.frame, "row-0") == null);
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                try ui.parser.feed("\x1b", sink);
                try ui.parser.expireEscape(sink);
                try ui.parser.feed("\x15", sink);
                try ui.draw();
                try std.testing.expect(std.mem.find(u8, ui.frame, "row-0") == null);
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                // Closing revokes the popup rows. Rows that lived only inside the
                // revoked overlay are not regenerated, but nothing is duplicated.
                for (0..history_length) |i| {
                    var marker: [16]u8 = undefined;
                    const value = try std.fmt.bufPrint(&marker, "row-{d:0>3}", .{i});
                    try std.testing.expect(screen.count(value) <= 1);
                }
                try std.testing.expect(screen.count("new-row") <= 1);
                // Pre-ABA overlay pixels are terminal-managed now and may survive
                // outside our ownership. Only the freshly ACKed tail is ours to
                // claim: locate it from the real cursor and tail geometry instead
                // of scanning the whole grid, and require no candidate inside it.
                const tail_bottom = screen.row + ui.tail_cursor_rows_up;
                try std.testing.expect(ui.tail_height != 0 and tail_bottom == screen.rows - 1);
                try std.testing.expect(tail_bottom + 1 >= ui.tail_height);
                const tail_top = tail_bottom + 1 - ui.tail_height;
                try std.testing.expect(tail_top <= screen.row);
                // An empty composer is not a menu candidate. Below 12 columns
                // presentation.prompt suppresses the model label, so the live
                // composer legitimately renders a plain "> " prompt. Derive
                // that prompt here rather than skipping composer-shaped rows:
                // the exemption below is exactly one cursor row, and every
                // other owned "> ..." row must still be rejected.
                const state_after = ui.connection.current();
                const narrow_prompt = try presentation.prompt(std.testing.allocator, state_after.model, null, dimensions.columns - 1, .{});
                defer narrow_prompt.deinit(std.testing.allocator);
                const plain_prompt = dimensions.columns < 12;
                if (plain_prompt) {
                    try std.testing.expectEqualStrings("> ", narrow_prompt.plain);
                } else {
                    // Wide layouts keep the model label, so the exemption is
                    // unreachable and a "> "-shaped row would still fail.
                    try std.testing.expect(!std.mem.startsWith(u8, narrow_prompt.plain, "> "));
                }
                try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
                for (tail_top..tail_bottom + 1) |owned| {
                    if (!std.mem.startsWith(u8, &screen.grid[owned], "> ")) continue;
                    // Sole permitted case: the actual cursor row holding the
                    // empty plain-"> " composer, text trimmed to ">", with the
                    // cursor resting exactly after the two-glyph prompt.
                    try std.testing.expect(plain_prompt);
                    try std.testing.expectEqual(screen.row, owned);
                    try std.testing.expectEqualStrings(">", std.mem.trim(u8, &screen.grid[owned], " "));
                    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
                    try std.testing.expectEqual(@as(usize, 2), screen.col);
                }
                try ui.parser.feed(command, sink);
                try ui.draw();
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                const resized: terminal_module.Size = if (dimensions.rows == 12)
                    .{ .columns = 80, .rows = 24 }
                else
                    .{ .columns = 16, .rows = 12 };
                ui.resize(resized);
                // This bounded no-reflow grid models the changed geometry;
                // every transcript marker fits both widths. No physical reflow
                // behavior or native viewport position is inferred here.
                screen.columns = resized.columns;
                screen.rows = resized.rows;
                screen.row = @min(screen.row, resized.rows - 1);
                screen.col = @min(screen.col, resized.columns - 1);
                try ui.draw();
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                try std.testing.expect(ui.tail_bottom and ui.tail_height != 0);
                try std.testing.expectEqual(resized.rows - 1, screen.row + ui.tail_cursor_rows_up);
                try std.testing.expectEqual(resized, ui.tail_size);
                const resized_menu_height = ui.tail_height;
                try ui.parser.feed("\x1b", sink);
                try ui.parser.expireEscape(sink);
                try ui.parser.feed("\x15", sink);
                try ui.draw();
                try std.testing.expect(std.mem.find(u8, ui.frame, "row-0") == null);
                try screen.replay(ui.frame);
                testAcknowledgeFullFrame(&ui);
                // After the geometry change only the owned tail is painted at the
                // new width; completed rows are neither reflowed nor replayed and
                // never duplicated.
                for (0..history_length) |i| {
                    var marker: [16]u8 = undefined;
                    const value = try std.fmt.bufPrint(&marker, "row-{d:0>3}", .{i});
                    try std.testing.expect(screen.count(value) <= 1);
                }
                try std.testing.expect(screen.count("new-row") <= 1);
                // The ACKed overlay footprint remains owned after an empty close;
                // only its current composer row and legitimate footer hint may contain text.
                try std.testing.expectEqual(resized_menu_height, ui.tail_height);
                try std.testing.expect(ui.tail_snapshot != null);
                try std.testing.expectEqual(resized, ui.tail_size);
                const resized_bottom = screen.row + ui.tail_cursor_rows_up;
                try std.testing.expectEqual(resized.rows - 1, resized_bottom);
                try std.testing.expect(resized_bottom + 1 >= ui.tail_height);
                const resized_top = resized_bottom + 1 - ui.tail_height;
                try std.testing.expect(screen.row >= resized_top and screen.row <= resized_bottom);
                try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const expected_hint = try ui.footerHint(arena.allocator(), ui.connection.current());
                try std.testing.expect(expected_hint.len != 0);
                try std.testing.expect(std.mem.indexOfScalar(u8, expected_hint, '\n') == null);
                try std.testing.expectEqual(@as(usize, 1), ui.tail_composer_rows);
                const cols = @max(1, resized.columns - 1);
                const expected_hint_prefix = expected_hint[0..text.fitBytes(expected_hint, cols)];
                for (resized_top..resized_bottom + 1) |owned| {
                    if (owned == screen.row) continue;
                    if (expected_hint.len != 0 and owned == resized_bottom - 1) {
                        try std.testing.expectEqualStrings(std.mem.trim(u8, expected_hint_prefix, " "), std.mem.trim(u8, &screen.grid[owned], " "));
                    } else {
                        try std.testing.expectEqualStrings("", std.mem.trim(u8, &screen.grid[owned], " "));
                    }
                }
            }
        }
    }
}
test "slash menu grows a short tail and cannot authorize a clipped panel" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    ui.tail_height = 2;
    try ui.parser.feed("/", sink);
    try ui.draw();
    try std.testing.expect(ui.frame_height >= 4);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/model") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "/login") != null);
    testAcknowledgeFullFrame(&ui);
    ui.resize(.{ .columns = 7, .rows = 6 });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\t", sink);
    try std.testing.expectEqualStrings("/", ui.editor.bytes.items);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.model_picker == null and !ui.secret_mode);
}
test "reasoning window grows below the committed user row and never borrows it" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 80, .rows = 24 };
    // A small bottom-anchored tail: the committed user row is directly above it.
    _ = try ui.add(.user, "stream-task");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const tail_before = ui.tail_height;
    try std.testing.expect(tail_before != 0 and tail_before < 6);
    try std.testing.expectEqual(screen.rows - ui.tail_height, ui.menu_history.?.above.len);
    try std.testing.expect(std.mem.indexOf(u8, ui.menu_history.?.above[ui.menu_history.?.above.len - 1], "stream-task") != null);
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-task"));
    const history_before = screen.history_len;
    try ui.appendDraft(.reasoning, "think-one\nthink-two\nthink-three\nthink-four");
    try ui.draw();
    try screen.replay(ui.frame);
    // The window is one leading gap plus its last row, grown downward
    // under the committed user row instead of borrowed upward over it.
    try std.testing.expectEqual(tail_before + 1 + reasoning_tail_rows, ui.frame_height);
    for ([_][]const u8{ "think-one", "think-two", "think-three" }) |marker| try std.testing.expect(!screen.visible(marker));
    try std.testing.expectEqual(@as(usize, 1), screen.count("think-four"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-task"));
    try expectTranscriptGap(&screen, "stream-task", "think-four");
    try std.testing.expect(screen.visible("stream-task"));
    try std.testing.expectEqual(history_before + 2, screen.history_len);
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), ui.menu_history.?.borrowed.len);
    const window_rows = ui.tail_height;
    // A later reasoning update repaints only that same row.
    try ui.appendDraft(.reasoning, "\nthink-five\nthink-six");
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(window_rows, ui.frame_height);
    for ([_][]const u8{ "think-two", "think-four", "think-five" }) |marker| try std.testing.expect(!screen.visible(marker));
    try std.testing.expectEqual(@as(usize, 1), screen.count("think-six"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-task"));
    try expectTranscriptGap(&screen, "stream-task", "think-six");
    try std.testing.expectEqual(history_before + 2, screen.history_len);
    testAcknowledgeFullFrame(&ui);
    // The canonical answer replaces the window; the user row is not replayed.
    try ui.appendDraft(.assistant, "final-answer");
    try std.testing.expect(ui.reasoning == null);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(@as(usize, 0), screen.count("think-"));
    try std.testing.expectEqual(@as(usize, 1), screen.count("stream-task"));
    try std.testing.expect(screen.visible("final-answer"));
    testAcknowledgeFullFrame(&ui);
}
test "inline stop during reasoning keeps user row and window visible" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 80, .rows = 24 };
    _ = try ui.add(.user, "stream-task");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    const tail_before = ui.tail_height;
    try std.testing.expect(tail_before != 0 and tail_before < 6);
    // The stop confirmation grows forward without covering the user or window.
    const history_before = screen.history_len;
    try ui.appendDraft(.reasoning, "think-one\nthink-two\nthink-three\nthink-four");
    ui.busy = true;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x03", sink);
    try std.testing.expect(ui.stop_open and !ui.stop_danger and !cancel.isRequested());
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(history_before + (ui.frame_height -| tail_before), screen.history_len);
    try std.testing.expectEqual(@as(usize, 0), ui.frame_borrow_rows);
    try std.testing.expectEqual(@as(usize, 0), ui.frame_menu_history.?.borrowed.len);
    try std.testing.expect(screen.visible("> Continue"));
    try std.testing.expect(screen.visible("Stop and clear"));
    for ([_][]const u8{ "think-one", "think-two", "think-three" }) |marker| try std.testing.expect(!screen.visible(marker));
    for ([_][]const u8{ "stream-task", "think-four" }) |marker| {
        try std.testing.expect(screen.visible(marker));
        try std.testing.expectEqual(@as(usize, 1), screen.count(marker));
    }
    try expectTranscriptGap(&screen, "stream-task", "think-four");
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), ui.menu_history.?.borrowed.len);
    const modal_history = screen.history_len;
    const modal_height = ui.tail_height;
    try Ui.key(&ui, .escape);
    try std.testing.expect(!ui.stop_open);
    try std.testing.expect(!cancel.isRequested());
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(modal_history + (ui.frame_height -| modal_height), screen.history_len);
    try std.testing.expectEqual(@as(usize, 0), ui.frame_borrow_rows);
    try std.testing.expectEqual(@as(usize, 0), ui.frame_menu_history.?.borrowed.len);
    try std.testing.expect(!screen.visible("> Continue"));
    for ([_][]const u8{ "think-one", "think-two", "think-three" }) |marker| try std.testing.expect(!screen.visible(marker));
    for ([_][]const u8{ "stream-task", "think-four" }) |marker| {
        try std.testing.expect(screen.visible(marker));
        try std.testing.expectEqual(@as(usize, 1), screen.count(marker));
    }
    try expectTranscriptGap(&screen, "stream-task", "think-four");
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), ui.menu_history.?.borrowed.len);
    try std.testing.expect(ui.tail_height >= tail_before);
    const restored_height = ui.tail_height;
    const restored_history = screen.history_len;
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqual(restored_height, ui.frame_height);
    try std.testing.expectEqual(restored_history, screen.history_len);
    for ([_][]const u8{ "think-one", "think-two", "think-three" }) |marker| try std.testing.expect(!screen.visible(marker));
    for ([_][]const u8{ "stream-task", "think-four" }) |marker|
        try std.testing.expectEqual(@as(usize, 1), screen.count(marker));
    try expectTranscriptGap(&screen, "stream-task", "think-four");
    try std.testing.expect(screen.visible("stream-task"));
    try std.testing.expectEqual(screen.rows - 1, screen.row);
    testAcknowledgeFullFrame(&ui);
}
test "resized reasoning frame revokes the old ACK without autonomous recovery" {
    try text.initLocale();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = 80, .rows = 24 };
    // Height-only shrink: the top `overflow` rows leave the viewport into native
    // history, the remaining rows move up, rows beyond the new logical height are
    // cleared, and the cursor drops by the same amount. Not a reflow model.
    const Shrink = struct {
        fn apply(target: *@import("../tests/regular_screen.zig").Screen, new_rows: usize) !void {
            const old_rows = target.rows;
            if (new_rows == 0 or new_rows >= old_rows or old_rows > target.grid.len) return;
            const overflow = old_rows - new_rows;
            if (target.history_len + overflow > target.history.len) return error.ScrollbackLimit;
            for (0..overflow) |i| target.history[target.history_len + i] = target.grid[i];
            target.history_len += overflow;
            for (0..new_rows) |row_index| target.grid[row_index] = target.grid[row_index + overflow];
            for (new_rows..target.grid.len) |row_index| target.grid[row_index] = @splat(' ');
            target.row -|= overflow;
            target.wrap = false;
            target.rows = new_rows;
        }
    };
    const markers = [_][]const u8{ "canon-c10", "canon-c11", "canon-c12", "canon-c13", "think-C" };
    // Tail footprint is content-derived: the bounded visible reasoning rows,
    // their leading gap, and the owned notice/separator/composer footer.
    const thinking_rows = reasoning_tail_rows;
    const thinking_gap = 1;
    const footer_rows = 3;
    const reasoning_footprint = thinking_rows + thinking_gap + footer_rows;
    try seedCompactAckedTail(&ui, &screen);
    try ui.appendDraft(.reasoning, "think-A\nthink-B\nthink-C");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    for (markers) |marker| try std.testing.expect(screen.count(marker) <= 1);
    // Partial geometry (same width, unknown height) grants no upward ownership.
    ui.tail_size = .{ .columns = ui.size.columns, .rows = ui.size.rows + 1 };
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "think-") == null);
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    for (markers) |marker| try std.testing.expect(screen.count(marker) <= 1);
    const records_before = ui.records.items.len;
    // Height-only resize invalidates every old ACKed geometry.
    ui.resize(.{ .columns = 80, .rows = 18 });
    try Shrink.apply(&screen, 18);
    // Resize is not content: no timer and no animation pulse may stage a frame.
    ui.clock_ms += 5000;
    ui.resize(.{ .columns = 80, .rows = 18 });
    ui.animate();
    try std.testing.expect(!ui.drawReady() and !ui.dirty and ui.frame.len == 0);
    try std.testing.expect(ui.tail_snapshot == null and !ui.tail_bottom and ui.abandon_tail);
    try std.testing.expectEqual(@as(usize, 18), ui.size.rows);
    // The next genuine update establishes a bounded bottom anchor without
    // clearing the screen or reclaiming old coordinates.
    ui.requestDraw();
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[999B") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "\x1b[0J") == null);
    try std.testing.expect(std.mem.startsWith(u8, ui.frame, terminal_module.sync_begin ++ "\x1b[?25l\r\x1b[18B"));
    // The bounded reasoning window carries its visible rows only; completed
    // canonical rows are neither reflowed nor replayed at the new width.
    try std.testing.expectEqual(reasoning_footprint, ui.frame_height);
    try std.testing.expect(std.mem.find(u8, ui.frame, "canon-c") == null);
    try screen.replay(ui.frame);
    // Old visible previews may remain after an interrupted geometry; they are
    // discarded display state, not a duplicate canonical record. No zero-ghost
    // or unique-viewport requirement survives the resize any more.
    try std.testing.expectEqual(records_before, ui.records.items.len);
    for (ui.records.items) |record| {
        if (record.kind == .reasoning) continue;
        try std.testing.expect(record.output);
    }
    // Freeze what that single frame produced; stability means no further
    // appends or duplicate rows, not that history matches the pre-resize state.
    var recovered: [markers.len]usize = undefined;
    for (markers, 0..) |marker, index| recovered[index] = screen.count(marker);
    const recovered_history = screen.history_len;
    testAcknowledgeFullFrame(&ui);
    // The fresh tail borrowed no unknown or old-width row.
    try std.testing.expectEqual(@as(usize, 0), ui.menu_history.?.borrowed.len);
    // The next stable frame keeps the same content-derived footprint without
    // replaying canonical rows.
    try ui.draw();
    try std.testing.expectEqual(reasoning_footprint, ui.frame_height);
    try screen.replay(ui.frame);
    for (markers, 0..) |marker, index| {
        try std.testing.expectEqual(recovered[index], screen.count(marker));
    }
    try std.testing.expectEqual(recovered_history, screen.history_len);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), ui.menu_history.?.borrowed.len);
}
test "slash menu never opens for pasted arguments unknown tokens or busy sessions" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[200~/login\x1b[201~", sink);
    try std.testing.expect(!ui.commandMenuVisible());
    try ui.parser.feed("\x15/Z", sink);
    try std.testing.expect(!ui.commandMenuVisible());
    try ui.parser.feed("\r", sink);
    try ui.parser.feed("/", sink);
    try std.testing.expect(ui.commandMenuVisible());
    ui.busy = true;
    ui.refreshCommandMenu();
    try std.testing.expect(!ui.commandMenuVisible());
}
test "model picker confirms acknowledged epoch and revision preserving transcript and context" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.size = .{ .columns = 80, .rows = 24 };
    _ = try ui.add(.user, "retained user");
    _ = try ui.add(.assistant, "retained answer");
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/model\r\x1b[B\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Search> ") != null);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqualStrings("fixture-next", fixture.name);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqual(@as(u32, 65536), ui.display.context.?.limit);
    try std.testing.expect(ui.model_picker == null);
    // An old in-flight menu may finish after close/reopen with revision 1.
    // Epoch acknowledgement prevents that frame authorizing the new menu.
    ui.openModelPicker();
    try ui.draw();
    try ui.modelKey(.cancel);
    ui.openModelPicker();
    testAcknowledgeFullFrame(&ui);
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
    try ui.draw();
    ui.resize(.{ .columns = 40, .rows = 12 });
    testAcknowledgeFullFrame(&ui);
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 2), fixture.selections);
}
test "selection guards paste secret busy joined future poison and rollback" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{};
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[200~/model pasted-id\x1b[201~\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.selections);
    try std.testing.expectEqualStrings("/model pasted-id", ui.editor.bytes.items);
    try ui.parser.feed("\x15/model fixture-next\r", sink);
    try std.testing.expectEqualStrings("fixture-next", fixture.name);
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(shared.ReasoningEffort.minimal, fixture.effort);
    // 切换档位后，输入框百分比位置短暂显示新档位名。
    try ui.draw();
    var effort_screen: @import("../tests/regular_screen.zig").Screen = .{};
    try effort_screen.replay(ui.frame);
    try std.testing.expect(effort_screen.visible("(fixture-next) minimal> "));
    testAcknowledgeFullFrame(&ui);
    // 5 秒后自动恢复为上下文百分比。
    ui.clock_ms = 5001;
    ui.expireEffortFlash();
    try ui.draw();
    try effort_screen.replay(ui.frame);
    try std.testing.expect(effort_screen.visible("(fixture-next) 1.5%> "));
    testAcknowledgeFullFrame(&ui);
    ui.busy = true;
    try ui.parser.feed("\x1b[Z/model busy-id\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
    try std.testing.expectError(error.Busy, ui.selectModel("busy-id"));
    try std.testing.expectEqual(@as(usize, 2), fixture.cycles);
    ui.busy = false;
    ui.future = ui.io.async(struct {
        fn noop() void {}
    }.noop, .{});
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 3), fixture.cycles);
    ui.future.?.await(ui.io);
    ui.future = null;
    ui.poisoned = true;
    try std.testing.expectError(error.Busy, ui.selectModel("poisoned"));
    ui.poisoned = false;
    fixture.fail = true;
    try std.testing.expectError(error.TestSelectionFailure, ui.selectModel("rejected"));
    try std.testing.expectEqualStrings("fixture-next", fixture.name);
    fixture.fail = false;
    ui.secret_quarantine = true;
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(@as(usize, 3), fixture.cycles);
    ui.secret_quarantine = false;
    ui.secret_mode = true;
    ui.parser.secretMode(true);
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(@as(usize, 3), fixture.cycles);
    ui.secret_mode = false;
    ui.parser.secretMode(false);
    ui.openModelPicker();
    try ui.modelKey(.paste_start);
    try ui.modelKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.selections);
    try ui.modelKey(.clear);
    try std.testing.expect(!ui.model_picker.?.pasted);
    try ui.modelKey(.escape);
    try std.testing.expect(ui.model_picker == null);
}
test "effort shortcut waits for queued and borrowed bridge items" {
    for ([_]bool{ false, true }) |borrowed| {
        var cancel = p.Cancellation{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var fixture = SelectionFixture{};
        defer fixture.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.connection = fixture.connection();
        const host = bridge.host();
        try host.emit_fn(host.context, .{ .context_snapshot = .{ .tokens = 12, .limit = 32768 } }, &cancel);
        var held = if (borrowed) bridge.pop() else null;
        defer if (held) |*item| item.deinit();
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed("\x1b[Z", sink);
        try std.testing.expectEqual(@as(usize, 0), fixture.cycles);
        try std.testing.expectEqual(shared.ReasoningEffort.off, fixture.effort);
        if (held) |*item| {
            item.deinit();
            held = null;
        } else {
            var item = bridge.pop().?;
            item.deinit();
        }
        try ui.parser.feed("\x1b[Z", sink);
        try std.testing.expectEqual(@as(usize, 1), fixture.cycles);
        try std.testing.expectEqual(shared.ReasoningEffort.minimal, fixture.effort);
    }
}
test "busy thinking shortcut keeps the running task and only queues the next level" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = SelectionFixture{ .effort = .low, .levels = .{ .mask = 0x55 } };
    defer fixture.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.size = .{ .columns = 80, .rows = 24 };

    // A live request: running mode, a streaming body draft, a tool row, its own
    // notice and a queued bridge item that belongs to this request.
    const body = try ui.add(.assistant, "streaming body");
    _ = try ui.add(.tool, "");
    ui.draft = body;
    ui.busy = true;
    ui.mode = .calling_model;
    ui.notice = "Pause pending";
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .context_snapshot = .{ .tokens = 12, .limit = 32768 } }, &cancel);
    const records = ui.records.items.len;

    ui.clock_ms = 1000;
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 1), fixture.cycles);
    try std.testing.expectEqual(shared.ReasoningEffort.high, fixture.effort);
    // The running task itself is untouched: still busy, same mode, same draft,
    // same body rows and the same count of records.
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(?r.State, .calling_model), ui.mode);
    try std.testing.expectEqual(@as(?usize, body), ui.draft);
    try std.testing.expectEqualStrings("streaming body", ui.records.items[body].body.items);
    try std.testing.expectEqual(records, ui.records.items.len);
    // Its notice is not replaced by an idle "Ready", and the bridge was neither
    // reset nor drained while the request still owns it.
    try std.testing.expectEqualStrings("Pause pending", ui.notice);
    var owned = bridge.pop().?;
    owned.deinit();
    // The confirmation is the existing five second composer flash.
    try std.testing.expectEqual(shared.ReasoningEffort.high, ui.effort_flash.?.level);
    try std.testing.expectEqual(@as(u64, 6000), ui.effort_flash.?.until_ms);

    // Paste and sensitive/policy overlays keep the original refusal priority.
    ui.editor_pasted = true;
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 1), fixture.cycles);
    ui.editor_pasted = false;
    ui.secret_mode = true;
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 1), fixture.cycles);
    try std.testing.expect(std.mem.find(u8, ui.notice, "idle, non-pasted") != null);
    ui.secret_mode = false;
    ui.stop_open = true;
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 1), fixture.cycles);
    ui.stop_open = false;
    ui.poisoned = true;
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 1), fixture.cycles);
    ui.poisoned = false;
    ui.parser.pasted = true;
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 1), fixture.cycles);
    ui.parser.pasted = false;
    // None of those refusals touched the running task either.
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(?usize, body), ui.draft);
    try std.testing.expectEqualStrings("streaming body", ui.records.items[body].body.items);
}
test "shutdown restores terminal and handles signals without announcing identity" {
    const c = std.c;
    const abi = @import("../platform/terminal_abi.zig");
    const Reader = struct {
        var terminal: *terminal_module.Terminal = undefined;
        var calls: usize = 0;
        var later: bool = false;
        fn read() u8 {
            std.debug.assert(terminal.restored and !terminal.active);
            calls += 1;
            return if (later and calls == 1) 0 else if (later) 2 else 15;
        }
    };
    for ([_]bool{ false, true }) |later| {
        var master: c_int = undefined;
        var slave: c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), abi.openpty(&master, &slave, null, null, null));
        defer _ = c.close(master);
        defer _ = c.close(slave);
        const flags = c.fcntl(slave, c.F.GETFL);
        const master_flags = c.fcntl(master, c.F.GETFL);
        try std.testing.expect(master_flags >= 0);
        try std.testing.expect(c.fcntl(master, c.F.SETFL, master_flags | @as(c_int, @bitCast(c.O{ .NONBLOCK = true }))) >= 0);
        var terminal = try terminal_module.Terminal.fromFd(slave, false);
        defer terminal.deinit();
        Reader.terminal = &terminal;
        Reader.calls = 0;
        Reader.later = later;
        try std.testing.expectEqual(@as(u8, if (later) 130 else 143), try finishExit(&terminal, 0, Reader.read));
        const posix = @import("../platform/posix_terminal.zig");
        try std.testing.expectEqual(posix.configuredFileFlags(flags), posix.configuredFileFlags(c.fcntl(slave, c.F.GETFL)));
        var bytes: [4096]u8 = undefined;
        const n = c.read(master, &bytes, bytes.len);
        try std.testing.expect(n > 0);
        try std.testing.expect(std.mem.indexOf(u8, bytes[0..@intCast(n)], "Session ID:") == null);
    }
}
test "cancellation alone cannot authorize exit but a parsed quit can" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    cancel.cancel();
    try std.testing.expect(cancel.isRequested() and !ui.ctrl_d_exit and !ui.exitAuthorized());
    try std.testing.expect(ui.settingsIdle());
    try ui.parser.feed("\x04", .{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expect(ui.ctrl_d_exit and ui.exitAuthorized());
    try std.testing.expect(!ui.settingsIdle());
}
test "CtrlD discards the remainder and all subsequent input before submission" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const previous_notice = ui.notice;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x04hello\r", sink);
    try std.testing.expect(ui.ctrl_d_exit and ui.exitAuthorized());
    try std.testing.expectEqualStrings(previous_notice, ui.notice);
    try ui.parser.feed("another\r", sink);
    try std.testing.expectEqualStrings(previous_notice, ui.notice);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    try std.testing.expect(ui.future == null and !ui.busy and ui.records.items.len == 0);
}
test "CtrlD exit reason survives secret quarantine picker and busy cancellation" {
    for (0..5) |mode_| {
        var cancel = p.Cancellation{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        switch (mode_) {
            1 => {
                ui.secret_mode = true;
                ui.parser.secretMode(true);
                ui.secret.insert("fake-exit-secret");
            },
            2 => ui.secret_quarantine = true,
            3 => ui.openModelPicker(),
            4 => ui.busy = true,
            else => {},
        }
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed("\x04", sink);
        try std.testing.expect(ui.ctrl_d_exit and ui.exitAuthorized());
        if (mode_ == 4) try std.testing.expect(cancel.requested.load(.acquire));
        if (mode_ == 1) {
            try std.testing.expect(!ui.secret_mode and ui.secret.len == 0);
            for (ui.secret.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }
}
test "compact slash menu requires acknowledged choice then joins a summary-only job" {
    const cfg = @import("../core/config.zig");
    var config = cfg.Config{ .provider = .{ .base_url = "http://localhost/fixture" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = AuthFixture{ .configured = true };
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fixture, .call_fn = AuthFixture.call }, .{ .context = &fixture, .schemas = &.{}, .prepare_fn = AuthFixture.prepare, .execute_fn = AuthFixture.execute }, bridge.host(), "");
    defer runtime.deinit();
    fixture.runtime = &runtime;
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/compact\r", sink);
    try std.testing.expectEqualStrings("No conversation to compact yet", ui.notice);
    try std.testing.expect(ui.future == null and !ui.busy);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    const old: [8192]u8 = @splat('a');
    const a = runtime.arena.allocator();
    try runtime.history.append(a, try p.textMessage(a, .user, &old));
    try runtime.history.append(a, try p.textMessage(a, .assistant, "old answer"));
    try runtime.history.append(a, try p.textMessage(a, .user, "latest goal"));
    try runtime.history.append(a, try p.textMessage(a, .assistant, "latest answer"));
    runtime.protected_index = 2;
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .context_snapshot = .{ .tokens = 1, .limit = 100 } }, &cancel);
    try ui.parser.feed("/compact\r", sink);
    try std.testing.expectEqualStrings("Compaction requires a drained session bridge", ui.notice);
    try std.testing.expect(ui.future == null);
    var pending = bridge.pop().?;
    pending.deinit();
    try ui.parser.feed("/compact unexpected\r", sink);
    try std.testing.expectEqualStrings("Usage: /compact (no arguments)", ui.notice);
    try std.testing.expect(ui.future == null);
    try ui.parser.feed("/co", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "/compact  Compact conversation") != null);
    try ui.parser.feed("\r", sink); // Built but not ACKed: no action.
    try std.testing.expect(ui.future == null);
    ui.frame_offset = 1;
    try ui.parser.feed("\r", sink); // Partial output still has no authority.
    try std.testing.expect(ui.future == null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.busy and ui.future != null and ui.prompt == null);
    try std.testing.expectEqual(.compact, ui.job.kind);
    try ui.complete();
    try std.testing.expect(!ui.busy and ui.future == null);
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expectEqual(@as(usize, 1), fixture.summary_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.normal_calls);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    for (runtime.messages()) |message| for (message.blocks) |block| {
        if (block == .text) try std.testing.expect(!std.mem.eql(u8, block.text, "/compact"));
    };
    try std.testing.expectEqual(p.Role.context, runtime.messages()[0].role);
    try std.testing.expect(!ui.last_terminal.?.context_snapshot.?.known);
}
test "bang commands use local job with zero main calls and reject unsafe submissions" {
    var config = core_config.Config{ .provider = .{ .base_url = "http://localhost/unused" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = AuthFixture{ .configured = true };
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fixture, .call_fn = AuthFixture.call }, .{ .context = &fixture, .schemas = &.{}, .prepare_fn = AuthFixture.prepare, .execute_fn = AuthFixture.execute }, bridge.host(), "");
    defer runtime.deinit();
    fixture.runtime = &runtime;
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    const sink: input.Sink = .{ .context = &ui, .emit_fn = Ui.key };
    for (0..6) |case| {
        ui.wipeEditor();
        _ = try ui.editor.insert(if (case == 0) " ! \t" else "!echo fixture");
        ui.busy = case == 1;
        ui.poisoned = case == 2;
        ui.editor_pasted = case == 3;
        ui.parser.escape_len = if (case == 4) 2 else 0;
        ui.ctrl_d_exit = case == 5;
        try ui.submit();
        try std.testing.expect(ui.future == null and ui.prompt == null);
        try std.testing.expectEqual(@as(usize, 0), fixture.calls);
        ui.busy = false;
        ui.poisoned = false;
        ui.ctrl_d_exit = false;
        ui.parser.escape_len = 0;
    }
    ui.wipeEditor();
    try ui.parser.feed("\x1b[200~!echo pasted\x1b[201~\r", sink);
    try std.testing.expect(ui.future == null);
    try ui.parser.feed("\r", sink); // Sticky paste remains untrusted.
    try std.testing.expect(ui.future == null);
    ui.wipeEditor();
    try ui.parser.feed("  !echo fixture  ", sink);
    try ui.parser.feed("\r!echo batch-tail\r", sink);
    try std.testing.expect(ui.busy and ui.future != null);
    try std.testing.expectEqual(.command, ui.job.kind);
    try std.testing.expectEqualStrings("  !echo fixture  ", ui.job.prompt);
    try std.testing.expectEqual(.executing_tool, ui.mode);
    try std.testing.expectEqualStrings("Running command", ui.notice);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    try ui.complete();
    try std.testing.expect(ui.future == null and !ui.busy);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    fixture.runtime = null;
    fixture.configured = false;
    try ui.parser.feed("!echo unavailable\r", sink);
    try std.testing.expect(ui.future == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}
test "compact command rejects busy pasted poisoned and unconfigured states without a job" {
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    for (0..3) |case| {
        _ = try ui.editor.insert("/compact");
        ui.busy = case == 0;
        ui.editor_pasted = case == 1;
        ui.poisoned = case == 2;
        try ui.submit();
        try std.testing.expect(ui.future == null);
        try std.testing.expectEqualStrings(if (case == 0) "Only ordinary conversation text can be queued" else "Compaction requires an idle, non-pasted session", ui.notice);
        if (case == 0) try std.testing.expectEqualStrings("/compact", ui.editor.bytes.items);
        ui.wipeEditor();
        ui.busy = false;
        ui.poisoned = false;
    }
    try ui.parser.feed("/compact\r", .{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expectEqualStrings("Not configured: use /login first", ui.notice);
}
test "unconfigured text and slash commands never create jobs or expose arguments" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("hello\r", sink);
    try std.testing.expectEqualStrings("Not configured: use /login first", ui.notice);
    try ui.parser.feed("/login sk-accidental-secret", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "sk-accidental-secret") == null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    for (ui.editor.bytes.allocatedSlice()) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try ui.parser.feed("/unknown\r", sink);
    try std.testing.expect(ui.future == null and !ui.busy and ui.prompt == null);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(NoticeLevel.failure, ui.records.items[0].notice_level);
    try ui.parser.feed("/login\rdiscard-command-batch-tail", sink);
    try std.testing.expect(ui.secret_mode and ui.secret.len == 0);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
}
test "slash composer frames keep model prefixes and hide credentials with command specific hints" {
    try text.initLocale();
    const cases = [_]struct { raw: []const u8, shown: []const u8, hidden: ?[]const u8 = null }{
        .{ .raw = "/model", .shown = "/model" },
        .{ .raw = "/model ", .shown = "/model " },
        .{ .raw = "/model\t", .shown = "/model    " },
        .{ .raw = "/model \t  ", .shown = "/model       " },
        .{ .raw = "/model provider/model-pre", .shown = "/model provider/model-pre" },
        .{ .raw = "/model malformed extra", .shown = "/model [arguments hidden; use one model ID]", .hidden = "malformed" },
        .{ .raw = "/login fakecredential", .shown = "/login [arguments hidden; no key argument]", .hidden = "fakecredential" },
        .{ .raw = "/compact fakecredential", .shown = "/compact [arguments hidden; no arguments]", .hidden = "fakecredential" },
        .{ .raw = "/unknown fakecredential", .shown = "/ [command arguments hidden]", .hidden = "fakecredential" },
    };
    for (cases) |case| {
        var cancel = p.Cancellation{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var fixture = SelectionFixture{};
        defer fixture.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.connection = fixture.connection();
        ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
        // Insert literal bytes: a physical Tab is a completion key, not an argument.
        _ = try ui.editor.insert(case.raw);
        try ui.draw();
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try screen.replay(ui.frame);
        try std.testing.expect(std.mem.find(u8, &screen.grid[screen.row], case.shown) != null);
        if (case.hidden) |hidden| {
            try std.testing.expect(std.mem.find(u8, ui.frame, hidden) == null);
            try std.testing.expectEqual(@as(usize, 0), screen.count(hidden));
        }
        if (!std.mem.startsWith(u8, case.raw, "/login")) {
            try std.testing.expect(std.mem.find(u8, &screen.grid[screen.row], "/login") == null);
        }
        try std.testing.expectEqualStrings(case.raw, ui.editor.bytes.items);
        testAcknowledgeFullFrame(&ui);
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed("\r", sink);
        try std.testing.expect(!ui.secret_mode and !ui.provider_open);
        try std.testing.expectEqual(@as(usize, 0), fixture.provider_saves);
    }
}
test "slash composer keeps supported management arguments visible without submitting" {
    try text.initLocale();
    const cases = [_]struct { raw: []const u8, shown: []const u8, hidden: ?[]const u8 = null }{
        .{ .raw = "/attach 0123456789abcdef0123456789abcdef", .shown = "/attach 0123456789abcdef0123456789abcdef" },
        .{ .raw = "/attach --takeover 0123456789abcdef0123456789abcdef", .shown = "/attach --takeover 0123456789abcdef0123456789abcdef" },
        .{ .raw = "/attch 0123456789abcdef0123456789abcdef", .shown = "/attch 0123456789abcdef0123456789abcdef" },
        .{ .raw = "/close 0123456789abcdef0123456789abcdef --force", .shown = "/close 0123456789abcdef0123456789abcdef --force" },
        .{ .raw = "/cd /srv/work dir", .shown = "/cd /srv/work dir" },
        .{ .raw = "/ls --running --page 2", .shown = "/ls --running --page 2" },
        .{ .raw = "/ls 2", .shown = "/ls 2" },
        .{ .raw = "/ls ", .shown = "/ls " },
        .{ .raw = "/detach   ", .shown = "/detach   " },
        .{ .raw = "/login ", .shown = "/login " },
        .{ .raw = "/compact\t", .shown = "/compact    " },
        .{ .raw = "/attach bad!id extra", .shown = "/ [command arguments hidden]", .hidden = "bad!id" },
        .{ .raw = "/ls --page", .shown = "/ [command arguments hidden]", .hidden = "--page" },
        .{ .raw = "/login fakecredential", .shown = "/login [arguments hidden; no key argument]", .hidden = "fakecredential" },
        .{ .raw = "/unknown fakecredential", .shown = "/ [command arguments hidden]", .hidden = "fakecredential" },
        .{ .raw = "/model one two", .shown = "/model [arguments hidden; use one model ID]", .hidden = "one two" },
    };
    for (cases) |case| {
        var cancel = p.Cancellation{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var fixture = SelectionFixture{};
        defer fixture.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.connection = fixture.connection();
        ui.connection.configure_provider_fn = SelectionFixture.configureProvider;
        _ = try ui.editor.insert(case.raw);
        try ui.draw();
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try screen.replay(ui.frame);
        try std.testing.expect(std.mem.find(u8, &screen.grid[screen.row], case.shown) != null);
        if (case.hidden) |hidden| {
            try std.testing.expect(std.mem.find(u8, ui.frame, hidden) == null);
            try std.testing.expectEqual(@as(usize, 0), screen.count(hidden));
        }
        // Drawing only: no command may run from a composer frame.
        try std.testing.expectEqualStrings(case.raw, ui.editor.bytes.items);
        try std.testing.expect(!ui.secret_mode and !ui.provider_open and ui.future == null and !ui.busy);
        try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
        try std.testing.expectEqual(@as(usize, 0), fixture.provider_saves);
        discardFixtureFrame(&ui);
    }
}
test "settings proxy submenu toggles one acknowledged row and keeps parent draft" {
    try text.initLocale();
    const models = [_]core_config.Model{
        .{ .name = "fixture/one", .context_tokens = 32768 },
        // Native protocol and unknown capacity remain selectable.
        .{ .name = "fixture/two", .protocol = .systemone, .context_tokens = 0 },
        .{ .name = "unlogged/three", .context_tokens = 32768 },
    };
    var fixture: SelectionFixture = .{ .profiles_override = &models, .proxy_configured = true, .proxy_address = "10.0.0.1", .proxy_port = 8080 };
    defer fixture.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 7;
    // Settings-root draft: the child must never destroy it.
    _ = try ui.editor.insert("draft");
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Proxy") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Proxy models") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "10.0.0.1:8080") != null);
    testAcknowledgeFullFrame(&ui);
    // Root Enter opens the second level; Address stays selected by default.
    try ui.parser.feed("\r", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expect(ui.proxy_sub_open and !ui.proxy_open and !ui.proxy_address_open);
    try std.testing.expect(ui.settings_model_picker == .none);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "> Address") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "10.0.0.1:8080") != null);
    testAcknowledgeFullFrame(&ui);
    // Down reaches Models, which opens the existing acknowledged picker.
    try ui.parser.feed("\x1b[B", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expect(ui.proxy_open and ui.proxy_sub_open and !ui.proxy_address_open);
    try std.testing.expect(ui.settings_model_picker == .none);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "[ ] fixture/one") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "unlogged/three") == null);
    testAcknowledgeFullFrame(&ui);
    // One ACKed Enter saves exactly one model; the same batch cannot flip twice.
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_saves);
    try std.testing.expectEqualStrings("fixture/one", fixture.proxy_last.?);
    try std.testing.expect(fixture.proxy_last_enabled);
    try std.testing.expect(publishedNotice(&ui, "Saved proxy models"));
    try std.testing.expect(publishedNotice(&ui, "new session"));
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_saves);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "[x] fixture/one") != null);
    testAcknowledgeFullFrame(&ui);
    // A second model can be toggled without leaving the submenu.
    try ui.parser.feed("\x1b[B", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 2), fixture.proxy_saves);
    try std.testing.expectEqualStrings("fixture/two", fixture.proxy_last.?);
    try std.testing.expectEqual(@as(usize, 2), fixture.proxy_len);
    // Owner save failure keeps the checkbox and the query, and still consumes ACK.
    fixture.proxy_fail = true;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 3), fixture.proxy_saves);
    try std.testing.expectEqual(@as(usize, 2), fixture.proxy_len);
    try std.testing.expect(std.mem.find(u8, ui.notice, "previous value kept") != null);
    try std.testing.expect(ui.proxy_open);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 3), fixture.proxy_saves);
    fixture.proxy_fail = false;
    // Search keeps the exact case and inner slashes of the saved name.
    try ui.settingsKey(.{ .text = .{ .value = "TWO", .pasted = false } });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 4), fixture.proxy_saves);
    try std.testing.expectEqualStrings("fixture/two", fixture.proxy_last.?);
    try std.testing.expect(!fixture.proxy_last_enabled);
    // Esc from the picker lands on the Models row and restores the parent draft.
    try ui.settingsKey(.escape);
    try std.testing.expect(!ui.proxy_open and ui.proxy_sub_open and ui.settings_open);
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
    try std.testing.expectEqualStrings("draft", ui.editor.bytes.items);
    // Esc from the second level returns to the root Proxy row, draft intact.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.escape);
    try std.testing.expect(!ui.proxy_sub_open and !ui.proxy_address_open and ui.settings_open);
    try std.testing.expectEqual(@as(usize, 7), ui.settings_menu.selected);
    try std.testing.expectEqualStrings("draft", ui.editor.bytes.items);
}
test "proxy picker owns its query while the parent submenu stays marked" {
    try text.initLocale();
    const models = [_]core_config.Model{
        .{ .name = "fixture/one", .context_tokens = 32768 },
        .{ .name = "fixture/two", .context_tokens = 32768 },
    };
    var fixture: SelectionFixture = .{ .profiles_override = &models, .proxy_configured = true, .proxy_address = "10.0.0.1", .proxy_port = 8080 };
    defer fixture.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 7;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try ui.settingsKey(.down);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    // Models opens the picker while the parent marker stays set.
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_open and ui.proxy_sub_open and !ui.proxy_address_open);
    // The query reaches the picker editor and filters its rows.
    try ui.settingsKey(.{ .text = .{ .value = "two", .pasted = false } });
    try std.testing.expectEqualStrings("two", ui.editor.bytes.items);
    try std.testing.expect(ui.proxy_open and ui.proxy_sub_open);
    try std.testing.expectEqual(@as(usize, 1), proxy_picker_module.count(SelectionFixture.current(&fixture).models, SelectionFixture.current(&fixture).model_providers, ui.editor.bytes.items));
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "[ ] fixture/two") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "fixture/one") == null);
    testAcknowledgeFullFrame(&ui);
    // A complete ACKed Enter toggles the filtered row instead of Address.
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_saves);
    try std.testing.expectEqualStrings("fixture/two", fixture.proxy_last.?);
    try std.testing.expect(fixture.proxy_last_enabled);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(ui.proxy_open and !ui.proxy_address_open);
    try std.testing.expectEqualStrings("two", ui.editor.bytes.items);
    try std.testing.expect(publishedNotice(&ui, "Saved proxy models"));
    // Esc still returns to the parent Models row, keeping the submenu.
    try ui.settingsKey(.escape);
    try std.testing.expect(!ui.proxy_open and ui.proxy_sub_open and !ui.proxy_address_open and ui.settings_open);
    try std.testing.expectEqual(@as(usize, 1), ui.settings_menu.selected);
}
test "settings proxy submenu reports a missing endpoint instead of stalling" {
    try text.initLocale();
    const models = [_]core_config.Model{.{ .name = "fixture/one", .context_tokens = 32768 }};
    var fixture: SelectionFixture = .{ .profiles_override = &models };
    defer fixture.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 7;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_sub_open and !ui.proxy_open);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Not configured") != null);
    testAcknowledgeFullFrame(&ui);
    // Models opens without an endpoint and states the blocker up front.
    try ui.parser.feed("\x1b[B", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_open);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Configure a proxy address first") != null);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "not configured") != null);
    testAcknowledgeFullFrame(&ui);
    // An acknowledged Enter still refuses to guess an endpoint or save a model.
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_saves);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Configure a proxy address first") != null);
    try std.testing.expect(ui.proxy_open);
    // Address opens with an empty prefill and an invalid value never lands.
    try ui.settingsKey(.escape);
    try ui.settingsKey(.up);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_address_open and ui.proxy_sub_open and !ui.proxy_open);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Address> ") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.{ .text = .{ .value = "fixture", .pasted = false } });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Invalid proxy address") != null);
    try std.testing.expect(ui.proxy_address_open and !fixture.proxy_configured);
    try std.testing.expect(ui.input_history.entries.items.len == 0);
    // The owner guard also refuses directly once settings became unavailable.
    const saves = fixture.proxy_address_saves;
    ui.saveProxyAddress(.{ .runtime = null, .model = "", .base_url = "", .global_settings_available = false });
    try std.testing.expectEqual(saves, fixture.proxy_address_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Global settings unavailable") != null);
    try std.testing.expect(ui.proxy_address_open);
}
test "proxy address enables model toggles and empty removes proxy configuration" {
    try text.initLocale();
    const models = [_]core_config.Model{.{ .name = "fixture/one", .context_tokens = 32768 }};
    var fixture: SelectionFixture = .{ .profiles_override = &models };
    defer fixture.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 7;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    // Root 7 -> second level -> Address, prefilled empty when nothing is set.
    try ui.settingsKey(.enter);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_address_open and ui.editor.bytes.items.len == 0);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("127.0.0.1:8888", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_address_saves);
    try std.testing.expectEqualStrings("127.0.0.1:8888", fixture.proxy_endpoint[0..fixture.proxy_endpoint_len]);
    try std.testing.expectEqualStrings("127.0.0.1", fixture.proxy_address.?);
    try std.testing.expectEqual(@as(u16, 8888), fixture.proxy_port);
    try std.testing.expect(fixture.proxy_configured);
    // A saved address returns to the second level, never to the editor.
    try std.testing.expect(!ui.proxy_address_open and ui.proxy_sub_open and !ui.proxy_open);
    try std.testing.expectEqual(@as(usize, 0), ui.settings_menu.selected);
    try std.testing.expect(publishedNotice(&ui, "Saved proxy address"));
    try std.testing.expect(publishedNotice(&ui, "new session"));
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "127.0.0.1:8888") != null);
    testAcknowledgeFullFrame(&ui);
    // Models now accepts one acknowledged toggle.
    try ui.settingsKey(.down);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_saves);
    try std.testing.expectEqualStrings("fixture/one", fixture.proxy_last.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_len);
    // Changing the address keeps the existing members.
    try ui.settingsKey(.escape);
    try ui.settingsKey(.up);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqualStrings("127.0.0.1:8888", ui.editor.bytes.items);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.clear);
    try ui.settingsKey(.{ .text = .{ .value = "10.0.0.1:3128", .pasted = false } });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 2), fixture.proxy_address_saves);
    try std.testing.expectEqualStrings("10.0.0.1", fixture.proxy_address.?);
    try std.testing.expectEqual(@as(u16, 3128), fixture.proxy_port);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_len);
    // Empty input removes the whole proxy through the same callback, dropping
    // the member list as the backend does; nothing survives the disable.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_address_open);
    try std.testing.expectEqualStrings("10.0.0.1:3128", ui.editor.bytes.items);
    try ui.settingsKey(.clear);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 3), fixture.proxy_address_saves);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_endpoint_len);
    try std.testing.expect(fixture.proxy_address == null and fixture.proxy_port == 0);
    try std.testing.expect(!fixture.proxy_configured);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_len);
    try std.testing.expectEqual(@as(usize, 0), SelectionFixture.current(&fixture).proxy_models.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_saves);
    try std.testing.expect(publishedNotice(&ui, "Empty disables proxy"));
    try std.testing.expect(!ui.proxy_address_open and ui.proxy_sub_open);
}
test "proxy address saves only when the endpoint fits the reserved columns" {
    try text.initLocale();
    const models = [_]core_config.Model{.{ .name = "fixture/one", .context_tokens = 32768 }};
    var fixture: SelectionFixture = .{ .profiles_override = &models };
    defer fixture.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 7;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_address_open);
    // 63+1+2 host plus ":8888" is 71 bytes; with the 9-byte prompt it needs
    // exactly the 80 reserved columns of an 81-column terminal.
    const endpoint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.aa:8888";
    try std.testing.expectEqual(@as(usize, 71), endpoint.len);
    try ui.parser.feed(endpoint, input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    // At 80 columns the row keeps one spare column, so the text is not fully
    // visible: the save is refused with a reason instead of silently failing.
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Resize") != null);
    try std.testing.expect(ui.proxy_address_open);
    // One wider column authorizes the same text after a fresh complete frame.
    ui.resize(.{ .columns = 81, .rows = 24 });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_address_saves);
    try std.testing.expectEqualStrings(endpoint, fixture.proxy_endpoint[0..fixture.proxy_endpoint_len]);
    try std.testing.expectEqual(@as(usize, 66), fixture.proxy_address.?.len);
    try std.testing.expectEqual(@as(u16, 8888), fixture.proxy_port);
    try std.testing.expect(!ui.proxy_address_open and ui.proxy_sub_open);
}
test "proxy address refuses invalid, canceled, pasted and unacknowledged saves" {
    try text.initLocale();
    const models = [_]core_config.Model{.{ .name = "fixture/one", .context_tokens = 32768 }};
    var fixture: SelectionFixture = .{ .profiles_override = &models, .proxy_configured = true, .proxy_address = "10.0.0.1", .proxy_port = 8080 };
    defer fixture.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 7;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expect(ui.proxy_address_open);
    try std.testing.expectEqualStrings("10.0.0.1:8080", ui.editor.bytes.items);
    // An invalid endpoint is refused explicitly and never lands.
    try ui.settingsKey(.clear);
    try ui.settingsKey(.{ .text = .{ .value = "10.0.0.1:0", .pasted = false } });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "Invalid proxy address") != null);
    try std.testing.expectEqualStrings("10.0.0.1", fixture.proxy_address.?);
    try std.testing.expect(ui.proxy_address_open);
    // Esc cancels without writing and the saved endpoint is still shown.
    try ui.settingsKey(.escape);
    try std.testing.expect(!ui.proxy_address_open and ui.proxy_sub_open);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "10.0.0.1:8080") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.settingsKey(.enter);
    try std.testing.expectEqualStrings("10.0.0.1:8080", ui.editor.bytes.items);
    // Text and Enter in one read batch cannot save: the edit revoked the ACK.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("9\r", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(ui.proxy_address_open);
    // Pasting only edits the buffer; the same batch Enter is refused too.
    try ui.settingsKey(.clear);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~10.0.0.9:3128\x1b[201~\r", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expectEqualStrings("10.0.0.9:3128", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), fixture.proxy_address_saves);
    try std.testing.expect(std.mem.find(u8, ui.notice, "pasted") != null);
    try std.testing.expect(ui.proxy_address_open);
    // An owner save failure keeps the previous endpoint and consumes the ACK.
    // The paste batch taints Enter for the rest of its read, so the attempt
    // arrives as a fresh read of its own after a complete frame.
    fixture.proxy_address_fail = true;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_address_saves);
    try std.testing.expectEqualStrings("10.0.0.1", fixture.proxy_address.?);
    try std.testing.expectEqual(@as(u16, 8080), fixture.proxy_port);
    try std.testing.expect(std.mem.find(u8, ui.notice, "previous value kept") != null);
    try std.testing.expect(ui.proxy_address_open);
    try ui.settingsKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fixture.proxy_address_saves);
    fixture.proxy_address_fail = false;
    // A fresh complete frame after the same edit does save it, and the retry
    // is again a new read rather than a byte of the previous one.
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", input.Sink{ .context = &ui, .emit_fn = Ui.key });
    try std.testing.expectEqual(@as(usize, 2), fixture.proxy_address_saves);
    try std.testing.expectEqualStrings("10.0.0.9", fixture.proxy_address.?);
    try std.testing.expectEqual(@as(u16, 3128), fixture.proxy_port);
    try std.testing.expect(!ui.proxy_address_open and ui.proxy_sub_open);
}
test "remote history replay seeds input history without touching the editor" {
    try text.initLocale();
    const a = std.testing.allocator;
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 5 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try typeDraft(&ui, "my draft");
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 1, .text = "first" } });
    fake.item.?.history_replay = true;
    fake.item.?.history_reset = true;
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("first", ui.input_history.entries.items[0]);
    try std.testing.expectEqualStrings("my draft", ui.editor.bytes.items);
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 2, .text = "second" } });
    fake.item.?.history_replay = true;
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expectEqual(@as(usize, 2), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("second", ui.input_history.entries.items[1]);
    // Live and queued events carry no replay marker and never duplicate history.
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 3, .text = "live" } });
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expectEqual(@as(usize, 2), ui.input_history.entries.items.len);
    // Truncated, incomplete, blank and slash-replayed text is skipped.
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 4, .text = "truncated" } });
    fake.item.?.history_replay = true;
    fake.item.?.display_truncated = true;
    try ui.pumpRemote();
    try drainBridge(&ui);
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 5, .text = "incomplete" } });
    fake.item.?.history_replay = true;
    fake.item.?.canonical_complete = false;
    try ui.pumpRemote();
    try drainBridge(&ui);
    for ([_][]const u8{ "   ", "  /secret command" }) |skipped| {
        fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 6, .text = skipped } });
        fake.item.?.history_replay = true;
        try ui.pumpRemote();
        try drainBridge(&ui);
    }
    try std.testing.expectEqual(@as(usize, 2), ui.input_history.entries.items.len);
    // Up/Down browse the replayed prompts and restore the unsent draft.
    ui.editor.cursor = 0;
    try Ui.key(&ui, .up);
    try std.testing.expectEqualStrings("second", ui.editor.bytes.items);
    try Ui.key(&ui, .down);
    try std.testing.expectEqualStrings("my draft", ui.editor.bytes.items);
    // A stale epoch item is discarded by the poll epoch check before any reset.
    fake.snapshot.control_epoch = 6;
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 7, .text = "stale" } });
    fake.item.?.history_replay = true;
    fake.item.?.history_reset = true;
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
}
test "remote history reset while browsing returns the unsent draft to the editor" {
    try text.initLocale();
    const a = std.testing.allocator;
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 5 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    for ([_][]const u8{ "old-one", "old-two" }) |message|
        ui.input_history.commit(a, try ui.input_history.prepare(a, message));
    try typeDraft(&ui, "unsent draft");
    ui.editor_pasted = true;
    // Browsing only starts at the exact raw origin, so the parked draft carries
    // cursor 0 and its pasted provenance; Up then shows the newest prompt.
    ui.editor.cursor = 0;
    try Ui.key(&ui, .up);
    try std.testing.expectEqualStrings("old-two", ui.editor.bytes.items);
    try std.testing.expect(ui.input_history.index != null and ui.history_draft != null and ui.history_draft_pasted);
    const parked = ui.history_draft.?.bytes.items.ptr;
    const parked_cursor = ui.history_draft.?.cursor;
    // A same-epoch replay reset replaces the list instead of dropping the form.
    fake.item = try session_client.ownEvent(a, 5, .{ .user_committed = .{ .id = 9, .text = "replayed" } });
    fake.item.?.history_replay = true;
    fake.item.?.history_reset = true;
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("replayed", ui.input_history.entries.items[0]);
    try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
    try std.testing.expectEqual(parked_cursor, ui.editor.cursor);
    try std.testing.expectEqual(parked, ui.editor.bytes.items.ptr); // moved owner, no copy
    try std.testing.expect(ui.editor_pasted);
    try std.testing.expect(ui.input_history.index == null and ui.history_draft == null and !ui.history_draft_pasted);
    // Down from the restored origin is not browsing: nothing is lost.
    try Ui.key(&ui, .down);
    try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
    try std.testing.expectEqual(parked, ui.editor.bytes.items.ptr);
    try std.testing.expect(ui.editor_pasted and ui.history_draft == null and ui.input_history.index == null);
}
test "secret prompt masks keys shows destination and erases cancel error and paste tails" {
    try text.initLocale();
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = AuthFixture{ .fail = true };
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/login\r", sink);
    try ui.parser.feed("sk-fixture-secret", sink);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "sk-fixture-secret") == null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "API key") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "http://localhost/fixture") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "fixture-model") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "*****") != null);
    try ui.parser.feed("\rsecret-error-tail", sink);
    try std.testing.expect(!ui.secret_mode and !fixture.configured);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    for (ui.secret.bytes) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try ui.parser.feed("/login\r", sink);
    try ui.parser.feed("erase\x7f\x1b[3~", sink);
    try std.testing.expectEqualStrings("era", ui.secret.value().?);
    try ui.parser.feed("\x15", sink);
    try std.testing.expectEqual(@as(usize, 0), ui.secret.len);
    try ui.parser.feed("\x1b[200~pasted\nkey\x1b[201~", sink);
    try std.testing.expect(ui.secret.failed);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(ui.secret_mode);
    try ui.parser.feed("\x03trailing-key", sink);
    try ui.parser.feed("more-tail\x1b[201~\r", sink);
    try std.testing.expect(!ui.secret_mode and ui.secret_quarantine);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(Kind.notice, ui.records.items[0].kind);
    try std.testing.expectEqual(NoticeLevel.failure, ui.records.items[0].notice_level);
    try std.testing.expectEqualStrings("Could not save configuration; use /login to retry", ui.records.items[0].body.items);
    for ([_][]const u8{ "sk-fixture-secret", "secret-error-tail", "pasted", "trailing-key", "more-tail" }) |sensitive| {
        try std.testing.expect(std.mem.find(u8, ui.records.items[0].body.items, sensitive) == null);
        try std.testing.expect(std.mem.find(u8, ui.frame, sensitive) == null);
    }
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
    for (ui.secret.bytes) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try ui.parser.feed("\x15", sink);
    try std.testing.expect(!ui.secret_quarantine);
    try ui.parser.feed("/login\r", sink);
    try ui.parser.feed("key\x04exit-tail", sink);
    try std.testing.expect(ui.ctrl_d_exit and ui.exitAuthorized() and !ui.secret_mode and ui.secret.len == 0);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
}
test "regression paste-tail Escape timeout cannot withdraw queued FollowUp" {
    try pasteTailEscapeRegression(&.{"\x1b[200~\x1b[201~\x1b"}, false);
}
test "regression split paste terminator Escape cannot revive after feed resets taint" {
    try pasteTailEscapeRegression(&.{ "\x1b[200~\x1b[20", "1~\x1b" }, true);
}
test "regression delayed paste-tail Escape retains provenance across fresh empty reads" {
    try pasteTailEscapeRegression(&.{"\x1b[200~\x1b[201~\x1b"}, true);
}
test "regression idle Custom Ctrl-C cancels child before parent via parser" {
    var fixture: PreferenceFixture = .{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.openSettingsMenu();
    ui.settings_menu.selected = 3;
    ui.openSettingsValue(.command_timeout_ms, fixture.state);
    ui.settings_menu.selected = try customPreferenceOption(ui.settings_value_picker.?);
    ui.settings_value_picker.?.beginCustom();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("123.456", sink);
    try std.testing.expect(ui.settings_value_picker.?.editing);
    try std.testing.expectEqualStrings("123.456", ui.settings_value_picker.?.input[0..ui.settings_value_picker.?.input_len]);
    try ui.parser.feed("\x03", sink);
    try std.testing.expect(!ui.settings_value_picker.?.editing);
    try std.testing.expect(ui.settings_open and !ui.stop_open);
    try std.testing.expectEqual(@as(usize, 0), ui.settings_value_picker.?.input_len);
    try ui.parser.feed("\x03", sink);
    try std.testing.expect(ui.settings_value_picker == null and ui.settings_open);
    try std.testing.expectEqual(@as(usize, 3), ui.settings_menu.selected);
    try ui.parser.feed("\x03", sink);
    try std.testing.expect(!ui.settings_open and !ui.stop_open and !cancel.isRequested());
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}
test "regression idle selectors Ctrl-C reaches child modal via parser" {
    for (0..4) |kind| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        switch (kind) {
            0, 1 => {
                ui.openSettingsMenu();
                ui.settings_model_picker = if (kind == 0) .decision else .image;
            },
            2 => ui.openModelPicker(),
            3 => ui.openProviderPicker(),
            else => unreachable,
        }
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        if (kind < 3) try ui.parser.feed("query", sink);
        try ui.parser.feed("\x03", sink);
        try std.testing.expect(!ui.settingsModelOpen() and ui.model_picker == null and !ui.provider_open);
        if (kind < 2) {
            try std.testing.expect(ui.settings_open);
            try std.testing.expectEqual(@as(usize, if (kind == 0) 1 else 5), ui.settings_menu.selected);
            try std.testing.expectEqualStrings("", ui.editor.bytes.items);
        }
        try std.testing.expect(!ui.stop_open and !cancel.isRequested());
    }
}
test "regression Ctrl-C still confirms busy or pending queue and keeps idle composer" {
    for (0..3) |kind| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.busy = kind == 0;
        if (kind == 1) {
            _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "pending");
            ui.openSettingsMenu(); // Queue confirmation outranks the idle modal.
        }
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        if (kind != 1) try ui.parser.feed("keep draft", sink);
        try ui.parser.feed("\x03", sink);
        try std.testing.expectEqual(kind != 2, ui.stop_open);
        try std.testing.expect(!ui.stop_danger and !cancel.isRequested());
        if (kind != 1) try std.testing.expectEqualStrings("keep draft", ui.editor.bytes.items);
        if (kind == 1) try std.testing.expectEqual(@as(usize, 1), ui.inbox.snapshot().follow_up);
    }
}
test "inline stop retains conversation queue and draft through selection and dismissal" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection.current_fn = FixtureConnection.configuredCurrent;
    defer ui.deinit();
    ui.busy = true;
    _ = try ui.add(.user, "prior stop conversation");
    _ = try ui.inbox.enqueue(std.testing.allocator, .steering, "keep-steer");
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "keep-follow");
    try std.testing.expect(try ui.editor.insert("same draft"));
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    ui.openStop();
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("prior stop conversation"));
    try std.testing.expect(screen.visible("keep-steer"));
    try std.testing.expect(screen.visible("keep-follow"));
    try std.testing.expect(std.mem.indexOf(u8, &screen.grid[screen.row], "Task running | Steering 1 FollowUp 1: [> Continue / Stop and clear]") != null);
    try std.testing.expectEqualStrings("same draft", ui.editor.bytes.items);
    try std.testing.expect(ui.displayed_stop == null);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .right);
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(std.mem.indexOf(u8, &screen.grid[screen.row], "> Stop and clear") != null);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .left);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .enter);
    try std.testing.expect(!ui.stop_open and !cancel.isRequested());
    try std.testing.expectEqual(@as(usize, 2), ui.inbox.snapshot().steering + ui.inbox.snapshot().follow_up);
    ui.openStop();
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .escape);
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(!ui.stop_open and !cancel.isRequested());
    try std.testing.expectEqualStrings("same draft", ui.editor.bytes.items);
    try std.testing.expect(screen.visible("same draft"));
    try std.testing.expectEqual(@as(usize, 2), ui.inbox.snapshot().steering + ui.inbox.snapshot().follow_up);
}
test "inline stop keeps unrelated persistent hint without repeating queue counts" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    _ = try ui.inbox.enqueue(std.testing.allocator, .steering, "retained queue");
    ui.openStop();
    ui.notice = "Operation pending; input kept";
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("Operation pending; input kept"));
    try std.testing.expect(screen.visible("Steering 1 FollowUp 0"));
    try std.testing.expect(!screen.visible("S:1 F:0"));
    try std.testing.expect(ui.frame_stop != null);
}
test "inline busy close offers safe cancel without closing" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    ui.openStop();
    ui.stop_close = try ui.allocator.dupe(u8, "fixture-session");
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(std.mem.indexOf(u8, &screen.grid[screen.row], "Close busy session | Steering 0 FollowUp 0: [> Cancel / Close session]") != null);
    try std.testing.expect(!ui.stop_danger and ui.frame_stop != null);
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .escape);
    try std.testing.expect(!ui.stop_open and !cancel.isRequested() and ui.stop_close == null);
}
test "higher priority input owners hide confirmations and frame authority" {
    for (0..4) |owner| {
        for (1..4) |combination| {
            var cancel: p.Cancellation = .{};
            var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
            defer bridge.deinit();
            var ui = fixtureUi(&bridge, &cancel);
            defer ui.deinit();
            defer {
                ui.secret_mode = false;
                ui.secret_quarantine = false;
                ui.codex_open = false;
                ui.codex_opening = false;
            }
            if (combination & 1 != 0) {
                try bridge.host().emit_fn(&bridge, .{ .permission = .{ .id = 12, .tool_name = "bash", .description = "preview" } }, &cancel);
                var item = bridge.pop().?;
                try ui.event(item);
                item.deinit();
            }
            if (combination & 2 != 0) {
                ui.busy = true;
                ui.openStop();
            }
            switch (owner) {
                0 => ui.secret_mode = true,
                1 => ui.secret_quarantine = true,
                2 => ui.codex_open = true,
                else => ui.codex_opening = true,
            }
            var screen: @import("../tests/regular_screen.zig").Screen = .{};
            try ui.draw();
            try screen.replay(ui.frame);
            try std.testing.expect(ui.frame_permission == null and ui.frame_stop == null);
            try std.testing.expect(!screen.visible("Approval #") and !screen.visible("Task running"));
            if (owner == 2) try std.testing.expect(screen.visible("Waiting for device code..."));
        }
    }
}
test "wrapped confirmation requires every row and narrow fallback never grants authority" {
    for ([_]bool{ false, true }) |approval| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.size = .{ .columns = if (approval) 17 else 26, .rows = 24 };
        if (approval) {
            try bridge.host().emit_fn(&bridge, .{ .permission = .{ .id = 12, .tool_name = "bash", .description = "preview" } }, &cancel);
            var item = bridge.pop().?;
            try ui.event(item);
            item.deinit();
        } else {
            ui.busy = true;
            ui.openStop();
        }
        var screen: @import("../tests/regular_screen.zig").Screen = .{ .columns = ui.size.columns };
        try ui.draw();
        try screen.replay(ui.frame);
        try std.testing.expect(ui.frame_composer_rows > 1 and ui.frame_composer_rows <= 3);
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(std.testing.allocator);
        for (screen.row + 1 - ui.frame_composer_rows..screen.row + 1) |row| {
            try joined.appendSlice(std.testing.allocator, std.mem.trimEnd(u8, screen.grid[row][0 .. screen.columns - 1], " "));
        }
        const expected = if (approval) "Approval #12: [Allow once / > Deny]" else "Task running | Steering 0 FollowUp 0: [> Continue / Stop and clear]";
        // Wrapping can split at spaces, so compare after removing spaces from both.
        var actual_compact: std.ArrayList(u8) = .empty;
        defer actual_compact.deinit(std.testing.allocator);
        for (joined.items) |byte| if (byte != ' ') {
            try actual_compact.append(std.testing.allocator, byte);
        };
        var expected_compact: std.ArrayList(u8) = .empty;
        defer expected_compact.deinit(std.testing.allocator);
        for (expected) |byte| if (byte != ' ') {
            try expected_compact.append(std.testing.allocator, byte);
        };
        try std.testing.expectEqualStrings(expected_compact.items, actual_compact.items);
        if (approval) try std.testing.expectEqual(@as(?u64, 12), ui.frame_permission) else try std.testing.expect(ui.frame_stop != null);
        testAcknowledgeFullFrame(&ui);
        ui.resize(.{ .columns = 12, .rows = 24 });
        try ui.draw();
        if (approval) try std.testing.expect(ui.frame_permission == null) else try std.testing.expect(ui.frame_stop == null);
        try std.testing.expect(!cancel.isRequested() and bridge.answer == null);
    }
}
test "stop clear requires fresh complete ACK and independent dangerous Enter with draft kept" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true; // Undefined fixture Runtime must never be dereferenced.
    _ = try ui.inbox.enqueue(std.testing.allocator, .steering, "queued steer");
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "queued followup");
    try std.testing.expect(try ui.editor.insert("keep my draft"));
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x03\x1b[C\r", sink);
    try std.testing.expect(ui.stop_open and !ui.stop_danger and !cancel.isRequested());
    try std.testing.expect(ui.inbox.snapshot().confirming);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "> Continue") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[C\r", sink);
    try std.testing.expect(ui.stop_danger and !cancel.isRequested());
    try ui.parser.feed("\r", sink); // No frame yet: no authorization.
    try std.testing.expect(!cancel.isRequested() and !ui.stop_danger);
    try ui.parser.feed("\x1b[C", sink); // Reselect after a pre-ACK/held Enter.
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "> Stop and clear") != null);
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r\x03", sink);
    try std.testing.expect(cancel.isRequested() and !ui.stop_open);
    try std.testing.expect(ui.inbox.snapshot().newest_id == null);
    try std.testing.expect(ui.inbox.snapshot().paused);
    try std.testing.expectEqualStrings("keep my draft", ui.editor.bytes.items);
}
test "stop modal rejects queue revision resize paste and repeated CtrlC authority" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x03", sink);
    try ui.parser.feed("\x1b[B", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "raced message");
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!cancel.isRequested() and !ui.stop_danger);
    try ui.parser.feed("\x1b[C", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    ui.resize(.{ .columns = 18, .rows = 7 });
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!cancel.isRequested());
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.displayed_stop == null);
    try ui.parser.feed("\r", sink);
    try std.testing.expect(!cancel.isRequested());
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.parser.feed("\x03\r", sink);
    try std.testing.expect(!ui.stop_danger and !cancel.isRequested());
    try ui.parser.feed("\x1b[C", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\x1b[200~\r\x1b[201~\r", sink);
    try std.testing.expect(!cancel.isRequested());
    // The discarded paste tail cannot confirm; fresh Esc solely dismisses.
    ui.parser.pasted = false;
    ui.parser.batch_paste = false;
    try Ui.key(&ui, .escape);
    try std.testing.expect(!ui.stop_open and !ui.inbox.snapshot().confirming);
    try std.testing.expectEqual(@as(usize, 1), ui.inbox.snapshot().follow_up);
}
test "Escape withdraws exact newest plain text once and preserves existing draft" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    _ = try ui.inbox.enqueue(std.testing.allocator, .steering, "first");
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "newest 中文");
    try Ui.key(&ui, .escape);
    try std.testing.expectEqualStrings("newest 中文", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), ui.inbox.snapshot().steering);
    try Ui.key(&ui, .escape);
    try std.testing.expectEqualStrings("newest 中文", ui.editor.bytes.items);
    try std.testing.expect(!cancel.isRequested());
    ui.wipeEditor();
    try Ui.key(&ui, .escape);
    try std.testing.expectEqualStrings("first", ui.editor.bytes.items);
    try std.testing.expect(!cancel.isRequested());
    ui.wipeEditor();
    try Ui.key(&ui, .cancel); // No real worker, but busy confirmation still safe.
    try Ui.key(&ui, .escape);
    try std.testing.expect(!cancel.isRequested() and !ui.stop_open);
    ui.busy = false;
    try std.testing.expect(try ui.editor.insert("idle draft"));
    try Ui.key(&ui, .cancel);
    try std.testing.expectEqualStrings("idle draft", ui.editor.bytes.items);
}
test "user committed is owned display only and permission cleared matches exact id" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try bridge.host().emit_fn(&bridge, .{ .user_committed = .{ .id = 9, .text = "injected actual text" } }, &cancel);
    var item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try std.testing.expectEqualStrings("injected actual text", ui.records.items[0].body.items);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    try bridge.host().emit_fn(&bridge, .{ .permission = .{ .id = 10, .tool_name = "bash", .description = "approval" } }, &cancel);
    item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try bridge.host().emit_fn(&bridge, .{ .permission_cleared = 9 }, &cancel);
    item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try std.testing.expect(ui.permission != null);
    try bridge.host().emit_fn(&bridge, .{ .permission_cleared = 10 }, &cancel);
    item = bridge.pop().?;
    try ui.event(item);
    item.deinit();
    try std.testing.expect(ui.permission == null);
}
test "ordinary submission preserves draft and pending queue after owner change" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var old_runtime: r.Runtime = undefined;
    var new_runtime: r.Runtime = undefined;
    var fixture = AuthFixture{ .configured = true, .runtime = &new_runtime };
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    ui.queue_owner = .{ .runtime = &old_runtime, .session = null };
    _ = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "old session pending");
    try std.testing.expect(try ui.editor.insert("new draft"));
    try Ui.key(&ui, .enter);
    try std.testing.expectEqualStrings("new draft", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), ui.inbox.snapshot().follow_up);
    try std.testing.expect(ui.inbox.snapshot().paused);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    try std.testing.expect(!ui.busy and ui.future == null and !ui.ctrl_d_exit and !ui.exitAuthorized());
    try std.testing.expect(std.mem.find(u8, ui.notice, "Ctrl-C") != null);
    ui.inbox.pauseClaims(true);
    try std.testing.expect(ui.inbox.cancelClear(ui.inbox.snapshot().revision, &cancel));
    try std.testing.expect(ui.queueOwnerMatches());
}
test "queued launch waits for joined success preserves draft and restores OOM without duplicate history" {
    const cfg = @import("../core/config.zig");
    var config = cfg.Config{ .provider = .{ .base_url = "http://localhost/fixture" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = AuthFixture{ .configured = true };
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fixture, .call_fn = AuthFixture.call }, .{ .context = &fixture, .schemas = &.{}, .prepare_fn = AuthFixture.prepare, .execute_fn = AuthFixture.execute }, bridge.host(), "");
    defer runtime.deinit();
    fixture.runtime = &runtime;
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    try std.testing.expect(try ui.editor.insert("first prompt"));
    try ui.submit();
    try std.testing.expect(runtime.inbox == &ui.inbox);
    try std.testing.expect(try ui.editor.insert("followup prompt"));
    try Ui.key(&ui, .follow_up);
    try std.testing.expectEqual(@as(usize, 1), ui.inbox.snapshot().follow_up);
    try std.testing.expect(try ui.editor.insert("unfinished draft"));
    try ui.dispatchNext();
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try ui.complete();
    try std.testing.expect(runtime.inbox == null and ui.attached_runtime == null);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    ui.allocator = failing.allocator();
    try ui.dispatchNext();
    ui.allocator = std.testing.allocator;
    try std.testing.expect(!ui.busy and ui.future == null);
    try std.testing.expectEqual(@as(usize, 1), ui.inbox.snapshot().follow_up);
    try std.testing.expect(ui.inbox.snapshot().paused);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("unfinished draft", ui.editor.bytes.items);
    // A normal submission must not silently resume the queue. Explicit resume
    // is tested here at the Inbox seam, without sending /queue to the model.
    ui.inbox.@"resume"();
    try ui.dispatchNext();
    try std.testing.expectEqualStrings("unfinished draft", ui.editor.bytes.items);
    try std.testing.expectEqualStrings("followup prompt", ui.prompt.?);
    try std.testing.expectEqual(@as(usize, 2), ui.input_history.entries.items.len);
    try ui.complete();
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), ui.inbox.snapshot().follow_up);
    try std.testing.expect(runtime.inbox == null);
}
test "configure enables same-process submit without sending secrets or commands" {
    const cfg = @import("../core/config.zig");
    var config = cfg.Config{ .provider = .{ .base_url = "http://localhost/fixture" }, .model = .{ .name = "fixture-model", .context_tokens = 32768, .protocol = .chat }, .limits = .{ .low_price_input = false } };
    var cancel = p.Cancellation{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fixture = AuthFixture{};
    var runtime = try r.Runtime.init(std.testing.allocator, std.testing.io, &config, .{ .context = &fixture, .call_fn = AuthFixture.call }, .{ .context = &fixture, .schemas = &.{}, .prepare_fn = AuthFixture.prepare, .execute_fn = AuthFixture.execute }, bridge.host(), "");
    defer runtime.deinit();
    fixture.runtime = &runtime;
    var ui = fixtureUi(&bridge, &cancel);
    ui.connection = fixture.connection();
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("not-yet\r", sink);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), runtime.messages().len);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    try ui.parser.feed("/login\r", sink);
    try ui.parser.feed("\x1b[200~sk-fixture-secret\x1b[201~", sink);
    try ui.parser.feed("\rsecret-tail", sink);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expect(publishedNotice(&ui, "Saved locally; send a message to connect"));
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "Saved locally; send a message to connect") != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "Esc closes") == null);
    try std.testing.expect(!ui.secret_mode and !ui.secret_quarantine);
    try std.testing.expect(std.mem.find(u8, ui.frame, "sk-fixture-secret") == null);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 1), fixture.saves);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqual(Kind.notice, ui.records.items[0].kind);
    try std.testing.expectEqual(NoticeLevel.failure, ui.records.items[0].notice_level);
    try std.testing.expectEqual(Kind.notice, ui.records.items[1].kind);
    try std.testing.expectEqual(NoticeLevel.plain, ui.records.items[1].notice_level);
    for (ui.secret.bytes) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try ui.parser.feed("/login\r", sink);
    try std.testing.expect(!ui.secret_mode);
    try std.testing.expectEqual(@as(usize, 1), fixture.saves);
    try ui.parser.feed("hello\r", sink);
    try std.testing.expect(ui.busy);
    try ui.complete();
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqualStrings("hello", runtime.messages()[0].blocks[0].text);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("hello", ui.input_history.entries.items[0]);
    var user_count: usize = 0;
    for (ui.records.items) |record| {
        if (record.kind == .user) {
            user_count += 1;
            try std.testing.expectEqualStrings("hello", record.body.items);
        }
        try std.testing.expect(std.mem.find(u8, record.body.items, "sk-fixture-secret") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), user_count);
}
test "resume root Tab completion and help show the remote command" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fake: FakeRemote = .{};
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("/res", sink);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\t", sink);
    try std.testing.expectEqualStrings("/resume", ui.editor.bytes.items);
    ui.wipeEditor();
    try typeDraft(&ui, "/help");
    try ui.submit();
    try std.testing.expect(publishedNotice(&ui, "/resume [id]"));
}
test "resume empty list and failed request preserve display and draft" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fake: FakeRemote = .{ .saved_fixture = &.{} };
    fake.snapshot.launcher_dir = "/one";
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.assistant, "complete old conversation");
    try typeDraft(&ui, "unsent draft");
    ui.openResumeRequest(fake.client());
    try std.testing.expect(ui.resume_picker == null and ui.resume_pending == null);
    try std.testing.expectEqualStrings("No saved sessions in this launcher directory", ui.notice);
    try std.testing.expectEqualStrings("complete old conversation", ui.records.items[0].body.items);
    try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
    fake.manage_failure = error.TestSelectionFailure;
    ui.openResumeRequest(fake.client());
    try std.testing.expect(ui.resume_pending == null);
    try std.testing.expectEqualStrings("complete old conversation", ui.records.items[0].body.items);
    try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
}
test "resume loading transfers the owned launcher and real sessions to the ready picker" {
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fake: FakeRemote = .{};
    fake.snapshot.launcher_dir = "/one";
    fake.snapshot.session_id = @as([32]u8, @splat(7));
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    ui.resume_serial = 41;
    try typeDraft(&ui, "unsent draft");
    ui.openResumeRequest(fake.client());
    const pending = ui.resume_pending.?;
    try std.testing.expect(ui.resume_picker == null);
    try std.testing.expectEqual(fake.snapshot.control_epoch, pending.epoch);
    try std.testing.expectEqualDeep(fake.snapshot.session_id, pending.session_id);
    try std.testing.expectEqualStrings("/one", pending.launcher.?);
    try std.testing.expect(pending.launcher.?.ptr != fake.snapshot.launcher_dir.?.ptr);
    try std.testing.expect(actions.requests[0].?.action.manage == .saved_sessions);
    const sessions = try std.testing.allocator.dupe(session_client.SavedSession, &resume_test_sessions);
    actions.complete(.{ .managed = .{ .saved_sessions = sessions } }, null, false);
    ui.pumpAsync();
    try std.testing.expect(ui.resume_pending == null);
    const picker = ui.resume_picker.?;
    try std.testing.expectEqual(pending.epoch, picker.epoch);
    try std.testing.expectEqualDeep(pending.session_id, picker.session_id);
    try std.testing.expect(pending.launcher.?.ptr == picker.launcher.?.ptr);
    try std.testing.expect(sessions.ptr == picker.sessions.ptr);
    try std.testing.expectEqualStrings(&resume_test_sessions[0].id, &picker.sessions[0].id);
    try std.testing.expectEqual(@as(u64, 42), picker.generation);
    try std.testing.expectEqual(ui.resume_serial, picker.generation);
    try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
    ui.closeResumePicker();
    try std.testing.expect(ui.resume_picker == null);
    // Teardown also owns the launcher of a load that never completed.
    ui.openResumeRequest(fake.client());
    try std.testing.expect(ui.resume_pending != null);
}
test "resume late list with changed epoch session or launcher remains outcome owned" {
    for (0..3) |change| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var fake: FakeRemote = .{};
        fake.snapshot.launcher_dir = "/one";
        var ui = remoteUi(&fake, &bridge, &cancel);
        defer ui.deinit();
        try typeDraft(&ui, "draft");
        ui.resume_pending = .{ .epoch = fake.snapshot.control_epoch, .session_id = fake.snapshot.session_id, .launcher = try std.testing.allocator.dupe(u8, "/one") };
        const sessions = try std.testing.allocator.dupe(session_client.SavedSession, &resume_test_sessions);
        var late: session_client.Outcome = .{ .saved_sessions = sessions };
        defer late.deinit(std.testing.allocator);
        switch (change) {
            0 => fake.snapshot.control_epoch += 1,
            1 => fake.snapshot.session_id = @as([32]u8, @splat(7)),
            else => fake.snapshot.launcher_dir = "/two",
        }
        ui.acceptManage(&late, true);
        try std.testing.expect(ui.resume_pending == null and ui.resume_picker == null);
        try std.testing.expect(sessions.ptr == late.saved_sessions.?.ptr);
        try std.testing.expectEqualStrings("draft", ui.editor.bytes.items);
        try std.testing.expectEqual(@as(usize, 0), fake.manages);
    }
}
test "resume fresh ACK partial clipped resize ABA navigation and paste cannot confirm" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fake: FakeRemote = .{ .saved_fixture = &resume_test_sessions };
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.openResumeRequest(fake.client());
    try ui.draw();
    ui.frame_offset = ui.frame.len / 2;
    ui.resumeKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fake.manages);
    testAcknowledgeFullFrame(&ui);
    const generation = ui.resume_picker.?.generation;
    try std.testing.expectEqual(@as(?u64, generation), ui.displayed_resume_generation);
    try ui.draw();
    try std.testing.expect(ui.frame.len != 0);
    try std.testing.expectEqual(@as(?u64, generation), ui.displayed_resume_generation);
    try std.testing.expectEqual(@as(?u64, generation), ui.frame_resume_generation);
    ui.frame_offset = ui.frame.len / 2;
    ui.resumeKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fake.manages);
    testAcknowledgeFullFrame(&ui);
    ui.resumeKey(.down);
    ui.resumeKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fake.manages);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    ui.resize(.{ .columns = 2, .rows = 24 });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    ui.resumeKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fake.manages);
    ui.resize(.{ .columns = 80, .rows = 24 });
    ui.resize(.{ .columns = 2, .rows = 24 });
    ui.resize(.{ .columns = 80, .rows = 24 });
    ui.resumeKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fake.manages);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[200~\r\x1b[201~\r", sink);
    try std.testing.expectEqual(@as(usize, 1), fake.manages);
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try ui.parser.feed("\r", sink);
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", fake.text[0..fake.text_len]);
    try std.testing.expect(ui.parser.stop_feed);
}
test "resume narrow title confirms the selected stable id even for duplicate titles" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fake: FakeRemote = .{ .saved_fixture = &resume_test_sessions };
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.resize(.{ .columns = 20, .rows = 24 });
    ui.openResumeRequest(fake.client());
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    ui.resumeKey(.down);
    ui.resumeKey(.enter);
    try std.testing.expectEqual(@as(usize, 1), fake.manages);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    ui.resumeKey(.enter);
    try std.testing.expectEqual(@as(usize, 2), fake.manages);
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", fake.text[0..fake.text_len]);
}
test "resume cancellation discards batch and stale session epoch launcher cannot execute" {
    for (0..3) |change| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var fake: FakeRemote = .{ .saved_fixture = &resume_test_sessions };
        fake.snapshot.launcher_dir = "/one";
        var ui = remoteUi(&fake, &bridge, &cancel);
        defer ui.deinit();
        try typeDraft(&ui, "draft");
        ui.openResumeRequest(fake.client());
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        switch (change) {
            0 => fake.snapshot.control_epoch += 1,
            1 => fake.snapshot.session_id = @as([32]u8, @splat(7)),
            else => fake.snapshot.launcher_dir = "/two",
        }
        ui.resumeKey(.enter);
        try std.testing.expectEqual(@as(usize, 1), fake.manages);
        try std.testing.expectEqualStrings("draft", ui.editor.bytes.items);
    }
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fake: FakeRemote = .{ .saved_fixture = &resume_test_sessions };
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try typeDraft(&ui, "draft");
    ui.openResumeRequest(fake.client());
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[D\r", sink);
    try std.testing.expect(ui.resume_picker == null);
    try std.testing.expectEqualStrings("draft", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
}
test "resume picker keeps complete display ownership and blocks confirmation batch tail" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fake: FakeRemote = .{ .saved_fixture = &resume_test_sessions };
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.user, "full previous user message");
    _ = try ui.add(.assistant, "full previous assistant answer\nsecond line");
    try typeDraft(&ui, "draft stays intact");
    ui.openResumeRequest(fake.client());
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\r\r", sink);
    try std.testing.expectEqual(@as(usize, 2), fake.manages);
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqualStrings("full previous user message", ui.records.items[0].body.items);
    try std.testing.expectEqualStrings("full previous assistant answer\nsecond line", ui.records.items[1].body.items);
    try std.testing.expectEqualStrings("draft stays intact", ui.editor.bytes.items);
}
test "resume failure keeps old display and success resets only on switched" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fake: FakeRemote = .{ .saved_fixture = &resume_test_sessions };
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.assistant, "entire old answer");
    try typeDraft(&ui, "unsent draft");
    ui.openResumeRequest(fake.client());
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    fake.manage_failure = error.TestSelectionFailure;
    ui.resumeKey(.enter);
    try std.testing.expectEqualStrings("entire old answer", ui.records.items[0].body.items);
    try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
    fake.manage_failure = null;
    fake.manage_switched = true;
    ui.openResumeRequest(fake.client());
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    ui.resumeKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
}
test "resume picker holds live draft stream rows until it closes" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fake: FakeRemote = .{ .saved_fixture = &resume_test_sessions };
    fake.snapshot.busy = true;
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try seedShiftDraft(&ui);
    const index = ui.draft.?;
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].stream_written != 0);
    ui.openResumeRequest(fake.client());
    try ui.draw();
    try std.testing.expect(ui.frame_resume_generation != null);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(ui.resume_picker.?.generation, ui.displayed_resume_generation.?);
    const written = ui.records.items[index].stream_written;
    const base = ui.records.items[index].stream.?.base;
    const history = ui.menu_history.?.above.len + ui.menu_history.?.borrowed.len;
    try ui.appendDraft(.assistant, "stream-row-035 abcdefghijklmnopqrstuvwxyz abcdefghijklmnop\nstream-row-036 abcdefghijklmnopqrstuvwxyz abcdefghijklmnop\n");
    try ui.draw();
    try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].pending_stream_rows);
    try std.testing.expectEqual(history, ui.frame_menu_history.?.above.len + ui.frame_menu_history.?.borrowed.len);
    for (ui.frame_records) |entry| if (entry.record_id == ui.records.items[index].id) {
        try std.testing.expectEqual(@as(usize, 0), entry.stream_rows);
        try std.testing.expect(!entry.metadata_staged);
    };
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(written, ui.records.items[index].stream_written);
    try std.testing.expectEqual(base, ui.records.items[index].stream.?.base);
    ui.closeResumePicker();
    try ui.draw();
    try std.testing.expect(ui.records.items[index].pending_stream_rows != 0);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expect(ui.records.items[index].stream_written > written);
    try std.testing.expect(ui.records.items[index].stream.?.base > base);
}
test "resume loading approval Escape denies without consuming list ownership" {
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fake: FakeRemote = .{};
    fake.snapshot.busy = true;
    fake.snapshot.launcher_dir = "/one";
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    try typeDraft(&ui, "unsent draft");
    ui.openResumeRequest(fake.client());
    const launcher = ui.resume_pending.?.launcher.?;
    try std.testing.expect(launcher.ptr != fake.snapshot.launcher_dir.?.ptr);
    fake.item = try session_client.ownEvent(std.testing.allocator, fake.snapshot.control_epoch, .{ .permission = .{ .id = 33, .tool_name = "bash", .description = "dangerous operation" } });
    try ui.pumpRemote();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(?u64, 33), ui.displayed_permission);
    ui.parser.stop_feed = false;
    try Ui.key(&ui, .escape);
    try std.testing.expect(ui.parser.stop_feed);
    try std.testing.expectEqual(@as(usize, 2), actions.next);
    try std.testing.expect(actions.requests[0].?.action.manage == .saved_sessions);
    const approval = actions.requests[1].?.action.approve;
    try std.testing.expectEqual(@as(u64, 33), approval.id);
    try std.testing.expectEqual(r.Decision.deny, approval.decision);
    try std.testing.expect(!std.mem.eql(u8, ui.notice, "Ready"));
    try std.testing.expect(ui.resume_pending.?.launcher.?.ptr == launcher.ptr);
    try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
    const sessions = try std.testing.allocator.dupe(session_client.SavedSession, &resume_test_sessions);
    actions.complete(.{ .managed = .{ .saved_sessions = sessions } }, null, false);
    ui.pumpAsync();
    try std.testing.expect(ui.resume_pending == null);
    try std.testing.expect(ui.resume_picker.?.launcher.?.ptr == launcher.ptr);
    try std.testing.expect(ui.resume_picker.?.sessions.ptr == sessions.ptr);
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expect(ui.permission == null);
    try std.testing.expect(publishedNotice(&ui, "Request denied"));
    try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
}
test "resume loading Escape cancels intent and ignores late list without cancelling task" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var fake: FakeRemote = .{};
    fake.snapshot.busy = true;
    fake.snapshot.launcher_dir = "/one";
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    try typeDraft(&ui, "pending draft");
    ui.resume_pending = .{ .epoch = fake.snapshot.control_epoch, .session_id = fake.snapshot.session_id, .launcher = try std.testing.allocator.dupe(u8, "/one") };
    try Ui.key(&ui, .escape);
    try std.testing.expect(ui.resume_pending == null and ui.parser.stop_feed);
    try std.testing.expectEqual(@as(usize, 0), fake.cancels);
    const sessions = try std.testing.allocator.dupe(session_client.SavedSession, &resume_test_sessions);
    var late: session_client.Outcome = .{ .saved_sessions = sessions };
    defer late.deinit(std.testing.allocator);
    ui.acceptManage(&late, true);
    try std.testing.expect(ui.resume_picker == null);
    try std.testing.expect(sessions.ptr == late.saved_sessions.?.ptr);
    try std.testing.expectEqualStrings("pending draft", ui.editor.bytes.items);
}
test "per-agent status rows" {
    try text.initLocale();
    const a = std.testing.allocator;
    var agents = [_]@import("../core/subagent_status.zig").AgentView{
        testAgent(1, 1, .running, 100, "FIRST-1"),
        testAgent(2, 1, .running, 200, "SECOND-2"),
        testAgent(3, 1, .waiting, 300, "THIRD-3"),
        testAgent(4, 1, .running, 400, "FOURTH-4"),
        testAgent(5, 1, .starting, 0, "FIFTH-5"),
    };
    var fake = FakeRemote{};
    fake.snapshot.subagents_supported = true;
    fake.snapshot.busy = true;
    fake.snapshot.subagents = .{ .group_id = 8, .revision = 1, .total = 4, .running = 3, .waiting = 1, .agents = agents[0..4] };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    try ui.observeSubagents();
    // Four real ids, four rows, four distinct texts: no aggregated count row.
    try std.testing.expectEqual(@as(usize, 4), ui.subagent_rows.items.len);
    try std.testing.expectEqual(@as(usize, 4), ui.records.items.len);
    for (ui.subagent_rows.items, 1..) |row, expected| try std.testing.expectEqual(@as(u64, @intCast(expected)), row.view.id);
    try ui.draw();
    for ([_][]const u8{ "#1 · running · FIRST-1", "#2 · running · SECOND-2", "#3 · waiting · THIRD-3", "#4 · running · FOURTH-4" }) |expected| {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ui.frame, expected));
    }
    try std.testing.expect(std.mem.find(u8, ui.frame, "4 running") == null);
    // Independent per-agent timers.
    for ([_][]const u8{ "100ms", "200ms", "300ms", "400ms" }) |expected| try std.testing.expect(std.mem.find(u8, ui.frame, expected) != null);
    ui.finishFrame(); // A partial frame is not delivery proof.
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    ui.resize(.{ .columns = 70, .rows = 24 });
    ui.resize(.{ .columns = 80, .rows = 24 });
    try std.testing.expect(!ui.frame_fresh);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    const record_ids = [4]u64{ ui.records.items[0].id, ui.records.items[1].id, ui.records.items[2].id, ui.records.items[3].id };
    // Updating the fourth agent leaves rows 1-3 exactly where they were.
    agents[3] = testAgent(4, 2, .running, 900, "FOUR-UPDATED");
    fake.snapshot.subagents.revision = 2;
    fake.snapshot.subagents.agents = agents[0..4];
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(usize, 4), ui.subagent_rows.items.len);
    try std.testing.expectEqual(@as(usize, 4), ui.records.items.len);
    try std.testing.expectEqual(@as(u64, 1), ui.subagent_rows.items[0].view.id);
    try std.testing.expectEqualStrings("FIRST-1", ui.subagent_rows.items[0].view.latestText());
    try std.testing.expectEqualStrings("SECOND-2", ui.subagent_rows.items[1].view.latestText());
    try std.testing.expectEqualStrings("THIRD-3", ui.subagent_rows.items[2].view.latestText());
    try std.testing.expectEqual(@as(u64, 4), ui.subagent_rows.items[3].view.id);
    try std.testing.expectEqualStrings("FOUR-UPDATED", ui.subagent_rows.items[3].view.latestText());
    try std.testing.expectEqual(@as(u64, 900), ui.subagent_rows.items[3].view.elapsed_ms);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "FOUR-UPDATED") != null);
    for (record_ids, 0..) |id, index| try std.testing.expectEqual(id, ui.records.items[index].id);
    // Sparse frames need not resend unchanged rows; inspect the retained record.
    try std.testing.expect(std.mem.find(u8, ui.records.items[0].body.items, "FIRST-1") != null);
    testAcknowledgeFullFrame(&ui);
    // The same revision with an advanced elapsed time still republishes.
    agents[0].elapsed_ms = 150;
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(u64, 150), ui.subagent_rows.items[0].view.elapsed_ms);
    // One terminal child neither settles nor hides the still-active others.
    agents[1] = testAgent(2, 2, .completed, 500, "SECOND-DONE");
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(usize, 4), ui.subagent_rows.items.len);
    try std.testing.expectEqual(presentation.Outcome.success, Ui.subagentPhaseOutcome(ui.subagent_rows.items[1].view));
    try std.testing.expectEqual(presentation.Outcome.pending, Ui.subagentPhaseOutcome(ui.subagent_rows.items[0].view));
    try std.testing.expectEqual(@as(usize, 4), ui.records.items.len);
    // All four terminal while the parent is busy keeps all four rows.
    agents[0] = testAgent(1, 2, .completed, 150, "FIRST-1");
    agents[2] = testAgent(3, 2, .failed, 700, "THIRD-FAILED");
    agents[3] = testAgent(4, 3, .completed, 950, "FOURTH-4");
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(usize, 4), ui.subagent_rows.items.len);
    try std.testing.expectEqual(@as(usize, 4), ui.records.items.len);
    try std.testing.expectEqual(presentation.Outcome.failed, Ui.subagentPhaseOutcome(ui.subagent_rows.items[2].view));
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    // A fifth real id appends exactly one more row.
    fake.snapshot.subagents.total = 5;
    fake.snapshot.subagents.agents = agents[0..5];
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(usize, 5), ui.subagent_rows.items.len);
    try std.testing.expectEqual(@as(u64, 5), ui.subagent_rows.items[4].view.id);
    try std.testing.expectEqual(@as(usize, 5), ui.records.items.len);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, "#5 · starting · FIFTH-5") != null);
    testAcknowledgeFullFrame(&ui);
    const fifth_record_id = ui.records.items[4].id;
    // Parent body follows all agent records and remains after settlement.
    const parent_index = try ui.add(.assistant, "PARENT-FINAL");
    try std.testing.expectEqual(@as(usize, 5), parent_index);
    for (ui.subagent_rows.items) |row| try std.testing.expect(ui.record_index.get(row.record_id).? < parent_index);
    // Parent settled: no additional agent records.
    agents[4] = testAgent(5, 2, .canceled, 1200, "FIFTH-CANCELED");
    fake.snapshot.busy = false;
    ui.busy = false;
    try ui.observeSubagents();
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(usize, 0), ui.subagent_rows.items.len);
    try std.testing.expectEqual(@as(usize, 6), ui.records.items.len);
    try std.testing.expectEqual(@as(?u64, 150), ui.records.items[0].duration_ms);
    try std.testing.expectEqual(@as(?u64, 500), ui.records.items[1].duration_ms);
    try std.testing.expectEqual(@as(?u64, 1200), ui.records.items[4].duration_ms);
    for (ui.records.items[0..5], 1..) |*record, expected| {
        const id = try std.fmt.allocPrint(a, "#{d} · ", .{expected});
        defer a.free(id);
        try std.testing.expect(std.mem.find(u8, record.body.items, id) != null);
    }
    try std.testing.expect(std.mem.find(u8, ui.records.items[2].body.items, "[error]") != null);
    try std.testing.expect(std.mem.find(u8, ui.records.items[4].body.items, "[canceled]") != null);
    // A settled group is never replayed by a later identical observation.
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(usize, 6), ui.records.items.len);
    try ui.draw();
    for (record_ids, 0..) |id, index| try std.testing.expectEqual(id, ui.records.items[index].id);
    try std.testing.expectEqual(fifth_record_id, ui.records.items[4].id);
    for ([_][]const u8{ "#1 · ", "#2 · ", "#3 · ", "#4 · " }) |id| try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ui.frame, id));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ui.frame, "#5 · canceled · FIFTH-CANCELED"));
    testAcknowledgeFullFrame(&ui);
    try ui.draw();
    for ([_][]const u8{ "#1 · ", "#2 · ", "#3 · ", "#4 · ", "#5 · " }) |id| try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, ui.frame, id));
    testAcknowledgeFullFrame(&ui);
}
test "active agent rows do not consume ordinary record capacity" {
    const a = std.testing.allocator;
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();

    for (1..66) |id| {
        try std.testing.expect(try ui.updateSubagentRow(testAgent(@intCast(id), 1, .running, 10, "live")));
    }
    try std.testing.expectEqual(@as(usize, 65), ui.records.items.len);
    for (ui.subagent_rows.items) |row| {
        const index = ui.record_index.get(row.record_id).?;
        try std.testing.expect(ui.records.items[index].agent_row);
        try std.testing.expect(ui.records.items[index].agent_open);
    }
    for (0..64) |_| _ = try ui.add(.user, "ordinary");
    _ = try ui.add(.user, "overflow");
    try std.testing.expectEqual(@as(usize, 130), ui.records.items.len);
    for (ui.subagent_rows.items) |row| try std.testing.expect(ui.record_index.contains(row.record_id));
}
test "per-agent status rows incomplete terminal pages" {
    const a = std.testing.allocator;
    var agents: [65]@import("../core/subagent_status.zig").AgentView = undefined;
    for (&agents, 1..) |*agent, id| agent.* = testAgent(@intCast(id), 1, .running, 10, "live");
    var fake = FakeRemote{};
    fake.snapshot.subagents_supported = true;
    fake.snapshot.busy = true;
    fake.snapshot.subagents = .{ .group_id = 8, .revision = 1, .total = 65, .running = 65, .agents = agents[0..64] };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(usize, 64), ui.records.items.len);
    for (&agents, 1..) |*agent, id| agent.* = testAgent(@intCast(id), 2, .completed, 20, "done");
    fake.snapshot.busy = false;
    fake.snapshot.subagents.revision = 2;
    ui.busy = false;
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(usize, 64), ui.subagent_rows.items.len);
    try std.testing.expectEqual(@as(u64, 0), ui.subagent_last_group);
    fake.snapshot.subagents.agents = &agents;
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(usize, 0), ui.subagent_rows.items.len);
    try std.testing.expectEqual(@as(u64, 8), ui.subagent_last_group);
    try std.testing.expectEqual(@as(usize, 65), ui.records.items.len);
    try std.testing.expect(std.mem.find(u8, ui.records.items[64].body.items, "#65 · completed · done") != null);
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(usize, 65), ui.records.items.len);
}
test "per-agent rows idle attachment and epoch replacement" {
    const a = std.testing.allocator;
    var agents = [_]@import("../core/subagent_status.zig").AgentView{
        testAgent(1, 1, .completed, 400, "OLD-DONE"),
        testAgent(2, 1, .running, 50, "LIVE-2"),
    };
    var fake = FakeRemote{};
    fake.snapshot.subagents_supported = true;
    fake.snapshot.control_epoch = 1;
    fake.snapshot.busy = false;
    fake.snapshot.subagents = .{ .group_id = 10, .revision = 1, .total = 1, .completed = 1, .agents = agents[0..1] };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // Idle attach never replays an already finished group.
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(usize, 0), ui.subagent_rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expectEqual(@as(u64, 10), ui.subagent_last_group);
    // A busy attach adopts the live group with its real ids.
    fake.snapshot.busy = true;
    ui.busy = true;
    fake.snapshot.subagents = .{ .group_id = 11, .revision = 1, .total = 2, .running = 1, .completed = 1, .agents = agents[0..2] };
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(u64, 11), ui.subagent_group);
    try std.testing.expectEqual(@as(usize, 2), ui.subagent_rows.items.len);
    // A control epoch switch drops the old unsettled rows without settling.
    fake.snapshot.control_epoch = 2;
    fake.snapshot.busy = false;
    fake.snapshot.subagents = .{ .group_id = 12, .revision = 1, .total = 1, .completed = 1, .agents = agents[0..1] };
    ui.busy = false;
    try ui.observeSubagents();
    try std.testing.expectEqual(@as(usize, 0), ui.subagent_rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expectEqual(@as(u64, 12), ui.subagent_last_group);
}
test "per-agent rows outcomes unsupported and history fallbacks" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(presentation.Outcome.success, Ui.subagentPhaseOutcome(testAgent(1, 1, .completed, 0, "")));
    try std.testing.expectEqual(presentation.Outcome.failed, Ui.subagentPhaseOutcome(testAgent(1, 1, .failed, 0, "")));
    try std.testing.expectEqual(presentation.Outcome.canceled, Ui.subagentPhaseOutcome(testAgent(1, 1, .canceled, 0, "")));
    try std.testing.expectEqual(presentation.Outcome.canceled, Ui.subagentPhaseOutcome(testAgent(1, 1, .paused, 0, "")));
    try std.testing.expectEqual(presentation.Outcome.pending, Ui.subagentPhaseOutcome(testAgent(1, 1, .running, 0, "")));
    var fake = FakeRemote{};
    fake.snapshot.subagents_supported = true;
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // Without subagent support the ordinary tool rows stay authoritative.
    fake.snapshot.subagents_supported = false;
    try ui.applyEvent(.{ .tool_result = .{ .id = 1, .name = "get_subagent_result", .result = .{ .text = "child report" } } }, false, true);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.subagent_rows.items.len);
    // A failed start keeps only the bounded notice; no aggregate row appears.
    fake.snapshot.subagents_supported = true;
    fake.snapshot.subagents = .{};
    ui.busy = true;
    try ui.applyEvent(.{ .tool_started = .{ .id = 7, .name = "subagent" } }, false, true);
    try std.testing.expect(ui.subagent_starting);
    try std.testing.expectEqual(@as(usize, 0), ui.subagent_rows.items.len);
    try ui.applyEvent(.{ .tool_result = .{ .id = 7, .name = "subagent", .result = .{ .text = "failure", .is_error = true } } }, false, true);
    try std.testing.expect(!ui.subagent_starting);
    try std.testing.expectEqualStrings("Subagent start failed", ui.notice);
    try std.testing.expectEqual(@as(usize, 0), ui.subagent_rows.items.len);
    // Replayed history never becomes a live per-agent row.
    ui.applying_history = true;
    try ui.applyEvent(.{ .tool_result = .{ .id = 8, .name = "subagent", .result = .{ .text = "old" } } }, false, true);
    ui.applying_history = false;
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.subagent_rows.items.len);
}
test "remote delivery requires a complete fresh frame and retries failed admission" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.finishFrame(); // Partial frame must not be proof.
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    ui.frame_offset = ui.frame.len;
    ui.frame_fresh = false;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    fake.ack_failure = true;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    fake.ack_failure = false;
    ui.retryDeliveryAck();
    try std.testing.expectEqual(@as(u64, 9), fake.ack_epoch);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, 1), fake.ack_count);
}
test "remote delivery retains source across batches and unsafe history reset" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    for (1..3) |sequence| {
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "pending text" });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = @intCast(sequence);
        try ui.pumpRemote();
    }
    const index = ui.draft.?;
    const before = ui.records.items[index].stream.?.windowBytes();
    try std.testing.expect(before != 0);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // Visibility contract: a complete fresh frame proves the mutable window it
    // actually displayed, so live delivery is acknowledged without EOF. The
    // Body still owns its source for future syntax.
    try std.testing.expectEqual(@as(usize, 1), fake.ack_count);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, before), ui.records.items[index].stream.?.windowBytes());
    // Accepted-but-undisplayed bytes stay unprovable: a later event that has no
    // frame yet keeps history display reset unsafe and the source retained.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = " late" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 3;
    try ui.pumpRemote();
    var baseline = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
    defer baseline.deinit();
    baseline.history_display_reset = true;
    ui.adoptReplayHistory(&baseline);
    try std.testing.expect(ui.replay_refused);
    try std.testing.expect(ui.records.items[ui.draft.?].stream.?.windowBytes() != 0);
}
test "history reset retains an assistant decoder holding CR or partial UTF8" {
    for ([_][]const u8{ "\r", "\xf0\x9f" }) |fragment| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        try ui.appendDraft(.assistant, fragment);
        const index = ui.draft.?;
        const id = ui.records.items[index].id;
        const stream = ui.records.items[index].stream.?;
        const cr = fragment[0] == '\r';
        try std.testing.expectEqual(@as(usize, 0), stream.windowBytes());
        try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].pending_stream_rows);
        try std.testing.expectEqual(ui.delivery_admitted, ui.delivery_acked);
        try std.testing.expectEqual(cr, stream.decoder.held_cr);
        try std.testing.expectEqual(@as(usize, if (cr) 0 else 2), stream.decoder.carry_len);
        var baseline = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
        defer baseline.deinit();
        baseline.history_display_reset = true;
        ui.adoptReplayHistory(&baseline);
        try std.testing.expect(ui.replay_refused);
        try std.testing.expectEqual(id, ui.records.items[ui.draft.?].id);
        try std.testing.expectEqualStrings("History reset refused; unacknowledged display retained", ui.notice);
        try std.testing.expectEqual(cr, stream.decoder.held_cr);
        try std.testing.expectEqual(@as(usize, if (cr) 0 else 2), stream.decoder.carry_len);
        // The retained decoder must still resolve the original source correctly.
        try ui.appendDraft(.assistant, if (cr) "\n" else "\x91\xa9");
        try std.testing.expectEqualStrings(if (cr) "\n" else "\xf0\x9f\x91\xa9", stream.source.items);
        try std.testing.expect(!stream.decoder.held_cr and stream.decoder.carry_len == 0);
    }
}
test "delivery coverage resolution never claims a cropped or replaced row" {
    const frozen = FrameRecord{ .record_id = 1, .generation = 1, .visible_complete = true, .stream_full_end = 60, .visible_source_end = 60 };
    const shown_tail = FrameRecord{ .record_id = 2, .generation = 1, .tail_line_start = 3, .tail_rows = 2, .stream_full_end = 90, .stream_prefix_end = 40 };
    const cropped_tail = FrameRecord{ .record_id = 3, .generation = 1, .tail_line_start = 0, .tail_rows = 2, .stream_full_end = 70, .stream_prefix_end = 30 };
    const replaced = FrameRecord{ .record_id = 4, .generation = 1, .stream_full_end = 50, .stream_prefix_end = 20 };
    const thinking = FrameRecord{ .record_id = 5, .generation = 1, .reasoning = true };
    var entries = [_]FrameRecord{ frozen, shown_tail, cropped_tail, replaced, thinking };
    resolveDeliveryCoverage(&entries, 0, 1, true);
    // Rows already released into native scrollback are displayed by definition.
    try std.testing.expect(entries[0].visible_complete);
    try std.testing.expectEqual(@as(usize, 60), entries[0].visible_source_end);
    // The whole mutable tail below the visible origin was written.
    try std.testing.expect(entries[1].visible_complete);
    try std.testing.expectEqual(@as(usize, 90), entries[1].visible_source_end);
    // A crop above the record's own rows leaves only the frozen prefix proven.
    try std.testing.expect(!entries[2].visible_complete);
    try std.testing.expectEqual(@as(usize, 30), entries[2].visible_source_end);
    // A modal replaced the body: no tail row of it was painted.
    try std.testing.expect(!entries[3].visible_complete);
    try std.testing.expectEqual(@as(usize, 20), entries[3].visible_source_end);
    try std.testing.expect(entries[4].visible_complete);
    // A deferred thinking window proves nothing until its newest rows are shown.
    var deferred = [_]FrameRecord{thinking};
    resolveDeliveryCoverage(&deferred, 0, 1, false);
    try std.testing.expect(!deferred[0].visible_complete);
    // Borrowed ACKed rows shift the tail; the record still counts as complete.
    var shifted = [_]FrameRecord{shown_tail};
    resolveDeliveryCoverage(&shifted, 2, 4, false);
    try std.testing.expect(shifted[0].visible_complete);
    var unshifted = [_]FrameRecord{shown_tail};
    resolveDeliveryCoverage(&unshifted, 0, 4, false);
    try std.testing.expect(!unshifted[0].visible_complete);
    try std.testing.expectEqual(@as(usize, 40), unshifted[0].visible_source_end);
}
test "inline approval withholds cropped body fences until the body is released" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = cropped_approval_body });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    ui.permission = .{ .id = 7, .description = try ui.allocator.dupe(u8, "run a command"), .clipped = false, .pasted = false, .epoch = 9 };
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("CROP-FIRST"));
    try std.testing.expect(screen.visible("CROP-LAST"));
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    // Closing the confirmation releases the cropped prefix into scrollback.
    ui.clearPermission();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
}
test "inline approval proves a visible short body only after a complete fresh frame" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "short visible body" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    ui.permission = .{ .id = 7, .description = try ui.allocator.dupe(u8, "run a command"), .clipped = false, .pasted = false, .epoch = 9 };
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(screen.visible("short visible body"));
    try std.testing.expect(ui.frame.len > 1);
    ui.frame_offset = ui.frame.len - 1;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
}
test "inline approval release repins cropped cached body without reparsing" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "shown" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "\n" ++ cropped_approval_body });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    const index = ui.draft.?;
    const body = ui.records.items[index].stream.?;
    ui.permission = .{ .id = 7, .description = try ui.allocator.dupe(u8, "run a command"), .clipped = false, .pasted = false, .epoch = 9 };
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expect(!screen.visible("CROP-FIRST"));
    try std.testing.expect(screen.visible("CROP-LAST"));
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    try std.testing.expect(!body.pinned);
    try std.testing.expect(ui.records.items[index].cache != null);
    const renders = body.stats.renders;
    const parsed_bytes = body.stats.window_bytes;
    ui.clearPermission();
    try ui.draw();
    try std.testing.expect(body.pinned);
    try std.testing.expectEqual(renders, body.stats.renders);
    try std.testing.expectEqual(parsed_bytes, body.stats.window_bytes);
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
}
test "an append during a pinned frame cannot extend its ACK snapshot" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "one" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw(); // Staged with admission snapshot 1 and a pinned render.
    try std.testing.expect(ui.frame.len != 0);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "two" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    try std.testing.expectEqual(@as(u64, 2), ui.delivery_admitted);
    // The next complete frame renders and proves the appended bytes.
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
}
test "a held CR blocks only its own fence while earlier rows progress" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .user_committed = .{ .id = 1, .text = "hello" } });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "abc\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // The committed user row is fully shown even though the body still holds a
    // pending CR byte that no row can represent yet.
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "\ndef" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 3;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 3), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 3), fake.ack_sequence);
}
test "metadata is selectively acknowledged while a data fence stays unmet" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "abc\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // The applied owner state is displayed, so it is acknowledged selectively...
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expectEqual(@as(usize, 1), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].first);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].last);
    // ...while the cumulative watermarks stop at the unprovable text event.
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expect(!ui.delivery_fences.items[0].proven);
    try std.testing.expect(ui.delivery_fences.items[0].record_id != 0);
}
test "metadata past a held CR hole is selectively acknowledged until the LF arrives" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // The seed ends in a CR: no row can represent that byte yet.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_range_count);
    // A modal frame never showed the body, so it cannot claim that source.
    ui.permission = .{ .id = 7, .description = try ui.allocator.dupe(u8, "run a command"), .clipped = false, .pasted = false, .epoch = 9 };
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    ui.clearPermission();
    // >1024 ordered metadata deltas behind that hole.
    var sequence: u64 = 2;
    var chunk: usize = 0;
    while (sequence <= 1100) : (sequence += 1) {
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = sequence;
        try ui.pumpRemote();
        chunk += 1;
        if (chunk == 1) {
            // Metadata must never inherit the body's unchanged CR target.
            for (ui.delivery_fences.items[1..]) |fence| {
                try std.testing.expectEqual(@as(u64, 0), fence.record_id);
                try std.testing.expectEqual(@as(usize, 0), fence.target);
            }
        }
        if (chunk == 200) {
            chunk = 0;
            try ui.draw();
            ui.frame_offset = ui.frame.len;
            ui.finishFrame();
        }
    }
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // The ring never needs to hold metadata that the UI already displayed.
    try std.testing.expect(fake.ack_range_count != 0);
    for (fake.ack_ranges[0..fake.ack_range_count]) |range| {
        try std.testing.expect(range.first >= 2);
        try std.testing.expect(range.last <= 1100);
    }
    // The held-CR hole stays retained and is never claimed by a watermark.
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expect(ui.delivery_fences.items.len >= 2);
    try std.testing.expect(!ui.delivery_fences.items[0].proven);
    try std.testing.expect(ui.delivery_fences.items[0].record_id != 0);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    // The LF resolves the byte; only now may the prefix cover everything.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "\n" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1101;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1101), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1101), ui.delivery_acked);
    try std.testing.expectEqual(@as(u64, 1101), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, 0), ui.delivery_fences.items.len);
}
test "a failed selective range keeps its exact interval for retry" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    var sequence: u64 = 2;
    while (sequence <= 4) : (sequence += 1) {
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = sequence;
        try ui.pumpRemote();
    }
    fake.ack_range_failure = true;
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_range_count);
    for (ui.delivery_fences.items) |fence| try std.testing.expect(!fence.enqueued);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    // Retrying re-sends exactly the same proven interval, never a wider claim.
    fake.ack_range_failure = false;
    ui.retryDeliveryAck();
    try std.testing.expectEqual(@as(usize, 1), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].first);
    try std.testing.expectEqual(@as(u64, 4), fake.ack_ranges[0].last);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
}
test "sparse event sequences are acknowledged as exact ranges, never bridged" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    for ([_]u64{ 2, 5, 9 }) |sequence| {
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = sequence;
        try ui.pumpRemote();
    }
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 3), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].first);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].last);
    try std.testing.expectEqual(@as(u64, 5), fake.ack_ranges[1].first);
    try std.testing.expectEqual(@as(u64, 5), fake.ack_ranges[1].last);
    try std.testing.expectEqual(@as(u64, 9), fake.ack_ranges[2].first);
    try std.testing.expectEqual(@as(u64, 9), fake.ack_ranges[2].last);
    // A high later sequence never advances the contiguous cursors over the hole.
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
}
test "a stalled selective ACK keeps cancel input live" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 1 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    fake.ack_range_failure = true;
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try Ui.key(&ui, .cancel);
    try std.testing.expect(ui.stop_open);
}
test "a missing range channel never closes a hole with a cumulative claim" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var vtable = FakeRemote.vtable;
    vtable.acknowledge_range_fn = null;
    var ui = remoteUi(&fake, &bridge, &cancel);
    ui.connection.session_client = .{ .context = &fake, .vtable = &vtable };
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .state = .calling_model });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expect(ui.delivery_range_unsupported);
    try std.testing.expect(std.mem.find(u8, ui.notice, "range ACK unsupported") != null);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expect(!ui.delivery_fences.items[0].proven);
}
test "a coalesced raw span is acknowledged as its full interval, not its last sequence" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // Primary body ends in a held CR: seq1 cannot be shown yet.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    // One coalesced reasoning payload standing for raw events 2..1024, which the
    // existing UX hides because prose already started.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .reasoning = "hidden reasoning tail" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_first_sequence = 2;
    fake.item.?.delivery_sequence = 1024;
    try ui.pumpRemote();
    try std.testing.expectEqual(@as(usize, 2), ui.delivery_fences.items.len);
    try std.testing.expectEqual(@as(u64, 2), ui.delivery_fences.items[1].first);
    try std.testing.expectEqual(@as(u64, 1024), ui.delivery_fences.items[1].sequence);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // The whole coalesced interval is claimed; the singleton 1024 would strand
    // raw sequences 2..1023 in the server ring.
    try std.testing.expectEqual(@as(usize, 1), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].first);
    try std.testing.expectEqual(@as(u64, 1024), fake.ack_ranges[0].last);
    // The CR hole still owns the contiguous cursors.
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expect(!ui.delivery_fences.items[0].proven);
    // The later LF releases the hole and the whole prefix together.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "\n" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_first_sequence = 1025;
    fake.item.?.delivery_sequence = 1025;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1025), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1025), ui.delivery_acked);
    try std.testing.expectEqual(@as(u64, 1025), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, 0), ui.delivery_fences.items.len);
}
test "an exactly empty payload inherits no held-CR source target" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // Primary body ends in a held CR: seq1 owns a source target no frame can
    // display yet.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "seed\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    const draft_id = ui.records.items[ui.draft.?].id;
    const held = ui.records.items[ui.draft.?].stream.?.acceptedSourceEnd();
    try std.testing.expect(held != 0);
    // One coalesced EMPTY text payload standing for raw events 2..1024. It
    // appends no source, so it must NOT be pointed at the draft's held-CR end:
    // that target can never be shown and would strand the whole interval in the
    // server ring until the finite fence queue blocks the resolving LF.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_first_sequence = 2;
    fake.item.?.delivery_sequence = 1024;
    try ui.pumpRemote();
    try std.testing.expectEqual(@as(usize, 2), ui.delivery_fences.items.len);
    const empty = ui.delivery_fences.items[1];
    try std.testing.expectEqual(@as(u64, 2), empty.first);
    try std.testing.expectEqual(@as(u64, 1024), empty.sequence);
    // Metadata fence: no record, no source, no reasoning ownership.
    try std.testing.expectEqual(@as(u64, 0), empty.record_id);
    try std.testing.expectEqual(@as(u64, 0), empty.generation);
    try std.testing.expectEqual(@as(usize, 0), empty.target);
    try std.testing.expect(!empty.reasoning);
    // The empty span added nothing to the body it did not own.
    try std.testing.expectEqual(draft_id, ui.records.items[ui.draft.?].id);
    try std.testing.expectEqual(held, ui.records.items[ui.draft.?].stream.?.acceptedSourceEnd());
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // Its OWN fresh frame proves the whole coalesced interval exactly, while the
    // CR hole still holds the contiguous cursors: no prefix release.
    try std.testing.expectEqual(@as(usize, 1), fake.ack_range_count);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_ranges[0].first);
    try std.testing.expectEqual(@as(u64, 1024), fake.ack_ranges[0].last);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expect(!ui.delivery_fences.items[0].proven);
    // A NON-EMPTY LF after that held CR does not move the accepted end at all
    // (the held CR byte becomes the real newline), yet it renders a newline and
    // keeps a real source obligation. "Accepted end unchanged" is therefore not
    // a rule for metadata fences; only the exact empty payload is.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "\n" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_first_sequence = 1025;
    fake.item.?.delivery_sequence = 1025;
    try ui.pumpRemote();
    const lf = ui.delivery_fences.items[ui.delivery_fences.items.len - 1];
    try std.testing.expectEqual(@as(u64, 1025), lf.sequence);
    try std.testing.expectEqual(draft_id, lf.record_id);
    try std.testing.expect(lf.target != 0);
    try std.testing.expect(!lf.reasoning);
    try std.testing.expectEqual(held, ui.records.items[ui.draft.?].stream.?.acceptedSourceEnd());
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // The resolving newline is displayed, so hole and interval settle together.
    try std.testing.expectEqual(@as(u64, 1025), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1025), ui.delivery_acked);
    try std.testing.expectEqual(@as(u64, 1025), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, 0), ui.delivery_fences.items.len);
}
test "an exactly empty reasoning payload keeps UX ownership without a new source" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // Thinking only: no prose has started, so the thinking window is the frame.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .reasoning = "think\r" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    const reasoning_index = ui.reasoning.?;
    const reasoning_id = ui.records.items[reasoning_index].id;
    // Thinking rows are owned by the bounded plain Tail, never by an active
    // assistant Body: the fixture must read the real owner, not a null stream.
    try std.testing.expect(ui.records.items[reasoning_index].stream == null);
    const reasoning_tail_ptr = ui.records.items[reasoning_index].tail;
    try std.testing.expect(reasoning_tail_ptr != null);
    const reasoning_tail = reasoning_tail_ptr.?;
    const held = reasoning_tail.writer.pos;
    const held_source_base = reasoning_tail.source_base;
    const held_source_len = reasoning_tail.source.items.len;
    const held_carry_len = reasoning_tail.carry_len;
    const held_cr = reasoning_tail.held_cr;
    // An empty coalesced reasoning span: it keeps the explicit thinking UX
    // ownership but requires no new source bytes.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .reasoning = "" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_first_sequence = 2;
    fake.item.?.delivery_sequence = 3;
    try ui.pumpRemote();
    const empty = ui.delivery_fences.items[ui.delivery_fences.items.len - 1];
    try std.testing.expectEqual(@as(u64, 2), empty.first);
    try std.testing.expectEqual(@as(u64, 3), empty.sequence);
    try std.testing.expect(empty.reasoning);
    try std.testing.expectEqual(reasoning_id, empty.record_id);
    try std.testing.expectEqual(@as(usize, 0), empty.target);
    try std.testing.expect(ui.records.items[reasoning_index].stream == null);
    try std.testing.expect(ui.records.items[reasoning_index].tail == reasoning_tail);
    try std.testing.expectEqual(held, reasoning_tail.writer.pos);
    try std.testing.expectEqual(held_source_base, reasoning_tail.source_base);
    try std.testing.expectEqual(held_source_len, reasoning_tail.source.items.len);
    try std.testing.expectEqual(held_carry_len, reasoning_tail.carry_len);
    try std.testing.expectEqual(held_cr, reasoning_tail.held_cr);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // A fresh frame that draws the newest thinking rows proves both sequences;
    // nothing waits for source bytes that were never appended.
    try std.testing.expectEqual(@as(usize, 0), fake.ack_range_count);
    try std.testing.expectEqual(@as(usize, 1), fake.ack_count);
    try std.testing.expectEqual(@as(u64, 3), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, 0), ui.delivery_fences.items.len);
}
test "incremental reasoning fences retain their owner and frame admission boundary" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    for ([_][]const u8{ "first", " second" }, 1..) |chunk, seq| {
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .reasoning = chunk });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = @intCast(seq);
        try ui.pumpRemote();
    }
    const index = ui.reasoning.?;
    const generation = ui.records.items[index].stream_generation;
    try std.testing.expectEqual(generation, ui.delivery_fences.items[0].generation);
    try std.testing.expectEqual(generation, ui.delivery_fences.items[1].generation);
    try ui.draw();
    // A partial frame is not an ACK; a later admission cannot inherit this frame.
    ui.frame_offset = ui.frame.len - 1;
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .reasoning = " third" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 3;
    try ui.pumpRemote();
    try std.testing.expectEqual(generation, ui.records.items[index].stream_generation);
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 3), fake.ack_sequence);
}
test "reasoning stale geometry and reset ABA never acknowledge old fences" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    for ([_][]const u8{ "first", " second" }, 1..) |chunk, seq| {
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .reasoning = chunk });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = @intCast(seq);
        try ui.pumpRemote();
    }
    const index = ui.reasoning.?;
    const generation = ui.records.items[index].stream_generation;
    try std.testing.expectEqual(generation, ui.delivery_fences.items[0].generation);
    try std.testing.expectEqual(generation, ui.delivery_fences.items[1].generation);
    try ui.draw();
    // A resize discards the frame even when geometry subsequently returns.
    ui.resize(.{ .columns = 79, .rows = 24 });
    ui.resize(.{ .columns = 80, .rows = 24 });
    try std.testing.expectEqual(@as(usize, 0), ui.frame.len);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try ui.draw();
    try ui.records.items[index].resetStream();
    try std.testing.expect(ui.records.items[index].stream_generation != generation);
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expectEqual(generation, ui.delivery_fences.items[0].generation);
}
test "canonical stream commit long finalized paragraph delivery waits for every native prefix" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 187, .rows = 39 };
    const source = try testLongCanonicalSource(std.testing.allocator, false);
    defer std.testing.allocator.free(source);
    const rendered = try markdown.render(std.testing.allocator, source, .{ .columns = 186, .max_lines = 8192 });
    defer markdown.release(std.testing.allocator, rendered);
    try std.testing.expect(!rendered.truncated);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .assistant_committed = &.{.{ .text = source }} });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    const index = ui.records.items.len - 1;
    const record = &ui.records.items[index];
    const body = record.stream.?;
    try std.testing.expectEqual(@as(usize, 1), ui.delivery_fences.items.len);
    const fence = ui.delivery_fences.items[0];
    try std.testing.expectEqual(record.id, fence.record_id);
    try std.testing.expectEqual(record.stream_generation, fence.generation);
    try std.testing.expectEqual(source.len, fence.target);
    var drawn: usize = 0;
    var frames: usize = 0;
    while (!record.output and frames < 100) : (frames += 1) {
        try ui.draw();
        try testNativePrefix(&ui, rendered.lines, &drawn);
        try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
        const complete = ui.frame_records[0].visible_complete;
        ui.frame_offset = ui.frame.len;
        ui.finishFrame();
        if (!complete) {
            try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
            try std.testing.expect(body.windowBytes() != 0);
            try std.testing.expect(!record.output);
        }
    }
    try std.testing.expect(frames > 1 and frames < 100);
    try std.testing.expectEqual(rendered.lines.len, drawn);
    try std.testing.expect(body.isDrained() and record.output);
    try std.testing.expectEqual(source.len, body.base);
    try std.testing.expectEqual(@as(usize, 1), fake.ack_count);
    try std.testing.expectEqual(@as(u64, 9), fake.ack_epoch);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 1), fake.ack_count);
}
test "canonical stream commit finalized render limit stays in mutable tail" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 187, .rows = 39 };
    const source = "W0001 abc中文 **bold** xyz";
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .assistant_committed = &.{.{ .text = source }} });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    const index = ui.records.items.len - 1;
    const body = ui.records.items[index].stream.?;
    body.max_rows = 0; // A real MarkdownRenderLimit, not a quantum yield.
    try ui.draw();
    try std.testing.expect(body.limit != .none);
    try std.testing.expectEqual(@as(usize, 0), body.visibleRows().len);
    try std.testing.expectEqual(@as(usize, 0), ui.frame_records[0].stream_rows);
    try std.testing.expect(!ui.frame_records[0].visible_complete);
    try std.testing.expect(std.mem.indexOf(u8, ui.frame[ui.frame_clear_end..], "[Display render limit; model history unchanged]") != null);
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), body.base);
    try std.testing.expectEqualStrings(source, body.source.items);
    try std.testing.expect(!ui.records.items[index].output);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expect(!std.mem.eql(u8, ui.notice, "Display commit incomplete; output retained"));
}
test "canonical stream commit empty heading EOF metadata requires a complete fresh unobscured frame" {
    for (0..4) |scenario| {
        var fake = FakeRemote{};
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = remoteUi(&fake, &bridge, &cancel);
        defer ui.deinit();
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "# " });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = 1;
        try ui.pumpRemote();
        const index = ui.draft.?;
        const body = ui.records.items[index].stream.?;
        try body.finish(); // Known EOF, while retaining the draft's flow ownership.
        if (scenario == 2) ui.permission = .{ .id = 7, .description = try ui.allocator.dupe(u8, "approval"), .clipped = false, .pasted = false, .epoch = 9 };
        try ui.draw();
        try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].lines.len);
        try std.testing.expectEqual(@as(usize, 1), ui.frame_records.len);
        try std.testing.expectEqual(scenario != 2, ui.frame_records[0].metadata_staged);
        try std.testing.expectEqual(@as(usize, 0), ui.frame_records[0].stream_rows);
        try std.testing.expect(body.hasMetadataProgress());
        try std.testing.expect(!body.isDrained());
        const capacity = body.arena.queryCapacity();
        try std.testing.expect(capacity > 0 and body.pinned);
        body.releaseDrainedRender();
        try std.testing.expectEqual(capacity, body.arena.queryCapacity());
        try std.testing.expectEqual(@as(usize, 0), body.base);
        try std.testing.expectEqual(@as(usize, 2), body.windowBytes());
        try std.testing.expectEqualStrings("# ", body.source.items);
        try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].delivery_visible);
        try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
        try std.testing.expect(ui.frame.len > 1);
        if (scenario == 0) {
            ui.frame_offset = ui.frame.len - 1;
            ui.finishFrame();
            try std.testing.expectEqual(capacity, body.arena.queryCapacity());
            try std.testing.expect(body.hasMetadataProgress());
            try std.testing.expect(!body.isDrained());
            try std.testing.expectEqual(@as(usize, 0), body.base);
            try std.testing.expectEqual(@as(usize, 2), body.windowBytes());
            try std.testing.expectEqualStrings("# ", body.source.items);
            try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].delivery_visible);
            try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
        } else if (scenario == 1) {
            ui.frame_fresh = false;
        } else if (scenario == 3) {
            ui.resize(.{ .columns = 79, .rows = 24 });
            ui.resize(.{ .columns = 80, .rows = 24 });
            try std.testing.expectEqual(@as(usize, 0), ui.frame.len);
        }
        if (scenario != 3) {
            ui.frame_offset = ui.frame.len;
            ui.finishFrame();
        }
        if (scenario != 0) {
            try std.testing.expectEqual(capacity, body.arena.queryCapacity());
            try std.testing.expect(!body.hasMetadataProgress());
            try std.testing.expectEqual(@as(usize, 0), body.base);
            try std.testing.expect(!body.isDrained());
            try std.testing.expectEqual(@as(usize, 2), body.windowBytes());
            try std.testing.expectEqualStrings("# ", body.source.items);
            try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].delivery_visible);
            try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
            if (scenario == 2) ui.clearPermission();
            if (scenario == 3) ui.requestDraw();
            try ui.draw();
            try std.testing.expect(body.hasMetadataProgress());
            try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].lines.len);
            try std.testing.expect(ui.frame_records[0].metadata_staged);
            ui.frame_offset = ui.frame.len;
            ui.finishFrame();
        }
        try std.testing.expect(!body.hasMetadataProgress());
        try std.testing.expect(body.isDrained());
        try std.testing.expectEqual(@as(usize, 2), body.base);
        try std.testing.expectEqual(@as(usize, 0), body.windowBytes());
        try std.testing.expectEqualStrings("", body.source.items);
        try std.testing.expectEqual(@as(usize, 2), ui.records.items[index].delivery_visible);
        try std.testing.expectEqual(@as(usize, 0), body.arena.queryCapacity());
        try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].lines.len);
        try std.testing.expect(ui.records.items[index].cache == null);
        try std.testing.expectEqual(@as(usize, 1), fake.ack_count);
        try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    }
}
test "literal reference definition requires a complete fresh unobscured frame" {
    for (0..3) |scenario| {
        var fake = FakeRemote{};
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = remoteUi(&fake, &bridge, &cancel);
        defer ui.deinit();
        const definition = "[r]: https://example.org/one\n\n";
        const payload = if (scenario == 2) definition ++ cropped_approval_body else definition;
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = payload });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = 1;
        try ui.pumpRemote();
        const index = ui.draft.?;
        const body = ui.records.items[index].stream.?;
        if (scenario == 2) ui.permission = .{ .id = 7, .description = try ui.allocator.dupe(u8, "approval"), .clipped = false, .pasted = false, .epoch = 9 };
        try ui.draw();
        if (scenario != 2) {
            try std.testing.expect(std.mem.indexOf(u8, ui.frame, "[r]: https://example.org/one") != null);
        } else {
            var screen: @import("../tests/regular_screen.zig").Screen = .{};
            try screen.replay(ui.frame);
            try std.testing.expect(!screen.visible("[r]: https://example.org/one"));
            try std.testing.expect(screen.visible("CROP-LAST"));
        }
        try std.testing.expectEqual(@as(usize, 0), body.base);
        try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].delivery_visible);
        if (scenario == 0) {
            try std.testing.expect(ui.frame.len > 1);
            ui.frame_offset = ui.frame.len - 1;
            ui.finishFrame();
            try std.testing.expectEqual(@as(usize, 0), body.base);
            try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
        } else if (scenario == 1) ui.frame_fresh = false;
        ui.frame_offset = ui.frame.len;
        ui.finishFrame();
        if (scenario != 0) {
            try std.testing.expectEqual(@as(usize, 0), body.base);
            try std.testing.expectEqual(@as(usize, 0), ui.records.items[index].delivery_visible);
            try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
            if (scenario == 2) ui.clearPermission();
            try ui.draw();
            ui.frame_offset = ui.frame.len;
            ui.finishFrame();
        }
        try std.testing.expect(ui.records.items[index].delivery_visible != 0);
        try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "later [two][r]\n" });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = 2;
        try ui.pumpRemote();
        try ui.draw();
        try std.testing.expect(std.mem.indexOf(u8, ui.frame, "[two][r]") != null);
        ui.frame_offset = ui.frame.len;
        ui.finishFrame();
        try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
    }
}
test "reference-looking syntax remains literal rather than resolving a link" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    const candidate = "[ref]: https://example.org/url\n";
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = candidate });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "[ref]: https://example.org/url") != null);
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "  \"title\"\n\n[link][ref]\n" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    try ui.draw();
    try std.testing.expect(std.mem.indexOf(u8, ui.frame, "[link][ref]") != null);
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
}
test "an unexplained generation replacement is never acknowledged, even later" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "abcdef" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    const index = ui.draft.?;
    // Nobody asked for this replacement: an ABA/generation mismatch is not
    // authority to ACK, neither through the stale frame nor any later one.
    try ui.records.items[index].resetStream();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    for (0..3) |_| {
        try ui.draw();
        ui.frame_offset = ui.frame.len;
        ui.finishFrame();
    }
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    // The fence kept its own generation; no inference rewrote it.
    try std.testing.expect(ui.delivery_fences.items[0].generation != ui.records.items[index].stream_generation);
    // Only an explicit canonical replacement retargets the same sequences to the
    // replacement's own display obligation, and only a fresh frame proves it.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .assistant_committed = &.{.{ .text = "abcdef" }} });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
}
test "256 CR-terminated events prove every earlier sequence while the last CR waits" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    var sequence: u64 = 1;
    while (sequence <= delivery_fence_capacity) : (sequence += 1) {
        const chunk = [2]u8{ 'a' + @as(u8, @intCast(sequence % 26)), '\r' };
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = &chunk });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = sequence;
        try ui.pumpRemote();
    }
    // Every event keeps its own ordered fence: the last target cannot swallow
    // the earlier ones, so the queue is exactly the bound.
    try std.testing.expectEqual(@as(usize, delivery_fence_capacity), ui.delivery_fences.items.len);
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // All shown prefixes are proven; only the pending CR byte (no row can
    // represent it yet) keeps the newest sequence outstanding.
    try std.testing.expectEqual(@as(u64, delivery_fence_capacity - 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, delivery_fence_capacity - 1), fake.ack_sequence);
    try std.testing.expectEqual(@as(usize, 1), ui.delivery_fences.items.len);
    // The resolving chunk settles the last sequence too.
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "\n" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = delivery_fence_capacity + 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, delivery_fence_capacity + 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, delivery_fence_capacity + 1), fake.ack_sequence);
}
test "a full delivery fence queue blocks polling without losing the event" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 1 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.delivery_epoch = 9;
    var sequence: u64 = 1;
    while (sequence <= delivery_fence_capacity) : (sequence += 1)
        ui.pushDeliveryFence(.{ .epoch = 9, .sequence = sequence });
    try std.testing.expectEqual(@as(usize, delivery_fence_capacity), ui.delivery_fences.items.len);
    try std.testing.expect(ui.displayBackpressured());
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "must not be consumed" });
    defer if (fake.item) |*item| item.deinit();
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = delivery_fence_capacity + 1;
    try ui.pumpDisplay();
    try std.testing.expect(fake.item != null);
    try std.testing.expectEqual(@as(usize, 0), bridge.len);
    try std.testing.expect(!ui.delivery_fault);
    try std.testing.expectEqual(@as(usize, delivery_fence_capacity), ui.delivery_fences.items.len);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
}
test "an event applied after the frame was built is never covered by it" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "abcdef" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    // Stage a frame, THEN apply an event whose target is already covered by the
    // pinned rows. The earlier admission snapshot cannot prove it.
    try ui.draw();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .assistant_committed = &.{.{ .text = "abcdef" }} });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    // A frame staged after that admission does cover it.
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
}
test "canonical replacement waits for its own rendered source" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "aaaa" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .assistant_committed = &.{.{ .text = "bbbbbbbb" }} });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    // The stale frame shows the retired generation, so it proves neither.
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    // Both sequences now own the replacement's source; the fresh frame proves it.
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
}
test "successive frames prove progressively more of one active body" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    // Comfortably more than the renderer's default 4 KiB work window.
    for (0..900) |_| try body.appendSlice(std.testing.allocator, "abcdef\n");
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = body.items });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    // The first window is displayed but the accepted tail is not; no ACK yet.
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    for (0..8) |_| {
        if (ui.delivery_proven == 1) break;
        try ui.draw();
        ui.frame_offset = ui.frame.len;
        ui.finishFrame();
    }
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    // Retained source is not EOF: the answer is still streaming in display terms.
    try std.testing.expect(ui.records.items[ui.draft.?].stream.?.windowBytes() != 0);
}
test "an unsupported ACK enqueue never retires live delivery" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var vtable = FakeRemote.vtable;
    vtable.acknowledge_fn = null;
    vtable.acknowledge_range_fn = null;
    var ui = remoteUi(&fake, &bridge, &cancel);
    ui.connection.session_client = .{ .context = &fake, .vtable = &vtable };
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "cannot ack" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(u64, 1), ui.delivery_proven);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_acked);
    try std.testing.expect(!ui.delivery_fault);
    // The lack of an ACK channel is reported, never treated as an ACK.
    try std.testing.expect(ui.delivery_ack_unsupported);
    try std.testing.expect(std.mem.find(u8, ui.notice, "ACK unsupported") != null);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
}
test "unmet delivery fence and record survive additional admissions" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.user, "old output");
    ui.records.items[0].output = true;
    _ = try ui.add(.user, "live tail");
    ui.draft = 1;
    ui.reasoning = 1;
    const id = ui.records.items[0].id;
    ui.pushDeliveryFence(.{ .epoch = 9, .sequence = 1, .record_id = id });
    for (0..70) |_| _ = try ui.add(.user, "later");
    try std.testing.expectEqual(id, ui.records.items[0].id);
    try std.testing.expectEqual(id, ui.delivery_fences.items[0].record_id);
    try std.testing.expect(!ui.delivery_fences.items[0].proven);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
}
test "remote approval delivery waits for higher priority owner to release" {
    for (0..4) |owner| {
        var fake = FakeRemote{};
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = remoteUi(&fake, &bridge, &cancel);
        defer ui.deinit();
        defer {
            ui.secret_mode = false;
            ui.secret_quarantine = false;
            ui.codex_open = false;
            ui.codex_opening = false;
        }
        fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .permission = .{ .id = 42, .tool_name = "bash", .description = "preview" } });
        fake.item.?.delivery_epoch = 9;
        fake.item.?.delivery_sequence = 1;
        try ui.pumpRemote();
        switch (owner) {
            0 => ui.secret_mode = true,
            1 => ui.secret_quarantine = true,
            2 => ui.codex_open = true,
            else => ui.codex_opening = true,
        }
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
        try std.testing.expectEqual(@as(u64, 0), fake.ack_sequence);
        ui.secret_mode = false;
        ui.secret_quarantine = false;
        ui.codex_open = false;
        ui.codex_opening = false;
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        try std.testing.expectEqual(@as(usize, 1), fake.ack_count);
        try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    }
}
test "remote approval waits for complete modal at narrow widths" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 10, .rows = 12 };
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .permission = .{ .id = 42, .tool_name = "bash", .description = "first line\nsecond line\nthird line\nfourth line\nfifth line" } });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    try std.testing.expect(ui.frame_permission == null);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try std.testing.expectEqual(@as(u64, 0), fake.ack_sequence);
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.draw();
    try std.testing.expectEqual(@as(?u64, 42), ui.frame_permission);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 1), fake.ack_count);
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
}
test "safe deny retires hidden remote approval and later delivery progresses" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.size = .{ .columns = 10, .rows = 12 };
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .permission = .{ .id = 42, .tool_name = "bash", .description = "preview" } });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try Ui.key(&ui, .escape);
    try std.testing.expectEqual(@as(usize, 1), fake.approvals);
    try std.testing.expect(ui.permission == null);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "following body\n" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpRemote();
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
    ui.resize(.{ .columns = 80, .rows = 24 });
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .finished = .{ .status = .success } });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 3;
    try ui.pumpDisplay();
    try ui.pumpDisplay();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(u64, 3), fake.ack_sequence);
}
test "remote terminal retires its hidden current approval" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .permission = .{ .id = 42, .tool_name = "bash", .description = "preview" } });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .finished = .{ .status = .canceled } });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 2;
    try ui.pumpDisplay();
    try ui.pumpDisplay();
    try std.testing.expect(ui.permission == null);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);
}
test "revoked hidden remote approval settles its delivery fence" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .permission = .{ .id = 42, .tool_name = "bash", .description = "preview" } });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = 1;
    try ui.pumpRemote();
    try ui.applyEvent(.{ .permission_cleared = 42 }, false, true);
    ui.retryDeliveryAck();
    try std.testing.expectEqual(@as(u64, 1), fake.ack_sequence);
}
test "successful independent notice preserves a pending failure alias" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.notice = "Could not start metadata refresh; previous cache kept";
    ui.notice_alias_pending = .{ .hash = std.hash.Wyhash.hash(0, ui.notice), .level = .failure };
    ui.publishNotice("Allowed once");
    try std.testing.expect(ui.notice_alias_pending != null);
    ui.observeAdvisories();
    try std.testing.expect(ui.notice_alias_pending == null);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqual(NoticeLevel.failure, ui.records.items[1].notice_level);
}
test "approval paging invalidates a partially written authority frame" {
    for ([_]input.Event{ .page_up, .page_down, .home, .end }) |page_key| {
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        try ui.applyEvent(.{ .permission = .{ .id = 1, .tool_name = "bash", .description = "one\ntwo\nthree\nfour" } }, false, true);
        bridge.pending = 1;
        try Ui.key(&ui, .left);
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        try ui.draw();
        ui.frame_offset = 1;
        try Ui.key(&ui, page_key);
        testAcknowledgeFullFrame(&ui);
        try Ui.key(&ui, .enter);
        try std.testing.expect(bridge.answer == null);
        try ui.draw();
        testAcknowledgeFullFrame(&ui);
        try Ui.key(&ui, .enter);
        try std.testing.expectEqual(@as(?r.Decision, .allow_once), bridge.answer);
    }
}
test "remote delivery rejects resized and stale record frames" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.admitDelivery(9, 1);
    try ui.draw();
    ui.discardResizedFrame();
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try ui.draw();
    var stale = [_]FrameRecord{.{ .record_id = 999999, .generation = 1 }};
    ui.frame_records = &stale;
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
}
test "UI reset failure keeps old epoch and bridge high-water until owned cleanup" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 1 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.user, "old cache");
    bridge.last_id = 42;
    ui.permission = .{ .id = 42, .description = try ui.allocator.dupe(u8, "old approval"), .clipped = false, .pasted = false, .epoch = 1 };
    ui.displayed_permission = 42;
    ui.admitDelivery(9, 1);
    try ui.draw();
    try std.testing.expectEqual(@as(?u64, 42), ui.frame_permission);
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .text = "queued" }, &cancel);
    var item = bridge.pop().?;
    fake.snapshot.control_epoch = 2;
    try std.testing.expectError(error.Busy, ui.pumpRemote());
    try std.testing.expectEqual(@as(u64, 1), ui.remote_epoch);
    try std.testing.expectEqual(@as(?u64, 42), bridge.last_id);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expect(ui.permission == null and ui.displayed_permission == null);
    try std.testing.expect(ui.frame_permission == null);
    try std.testing.expect(ui.frame.len == 0 and !ui.frame_fresh);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqualStrings("UI reset failed; reattach to resync", ui.notice);
    item.deinit();
    try ui.pumpRemote();
    try std.testing.expectEqual(@as(u64, 2), ui.remote_epoch);
    try std.testing.expect(bridge.last_id == null);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expect(ui.displayed_permission == null and !ui.frame_fresh);
    try std.testing.expectEqualStrings("Ready", ui.notice);
}
test "UI reset failure preserves parked editor on management switch" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 1 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try typeDraft(&ui, "parked draft");
    ui.editor_pasted = true;
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .text = "queued" }, &cancel);
    fake.snapshot.control_epoch = 2;
    var outcome: session_client.Outcome = .{ .switched = true };
    ui.acceptManage(&outcome, true);
    try std.testing.expectEqualStrings("parked draft", ui.editor.bytes.items);
    try std.testing.expect(ui.editor_pasted);
    try std.testing.expectEqual(@as(u64, 1), ui.remote_epoch);
    try std.testing.expectEqualStrings("UI reset failed; reattach to resync", ui.notice);
    try std.testing.expect(!ui.settingsIdle());
    try std.testing.expect(!try ui.remoteStart(fake.client(), .prompt, ui.editor.bytes.items));
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
    try std.testing.expectEqualStrings("parked draft", ui.editor.bytes.items);
    var item = bridge.pop().?;
    item.deinit();
    try ui.pumpRemote();
    try std.testing.expect(!ui.remoteSynchronizing());
    try std.testing.expectEqual(@as(u64, 2), ui.remote_epoch);
}
test "remote delivery revokes pending proof on epoch takeover" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.admitDelivery(9, 1);
    try ui.draw();
    fake.snapshot.control_epoch = 2;
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try ui.resetSessionView(&fake.snapshot);
    ui.retryDeliveryAck();
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_proven);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
}
test "display admission leaves remote event queued while cancel input remains live" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 1 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    var sequence: u64 = 1;
    while (sequence <= delivery_fence_capacity) : (sequence += 1) ui.admitDelivery(9, sequence);
    try std.testing.expect(ui.displayBackpressured());
    fake.item = try session_client.ownEvent(std.testing.allocator, 1, .{ .text = "not consumed" });
    fake.item.?.delivery_epoch = 9;
    fake.item.?.delivery_sequence = delivery_fence_capacity + 1;
    defer if (fake.item) |*item| item.deinit();
    try ui.pumpDisplay();
    try std.testing.expect(fake.item != null);
    try std.testing.expectEqual(@as(usize, 0), bridge.len);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    try Ui.key(&ui, .cancel);
    try std.testing.expect(ui.stop_open);
    try Ui.key(&ui, .escape);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(u64, delivery_fence_capacity), ui.delivery_acked);
    try ui.pumpDisplay();
    try std.testing.expect(fake.item == null);
    try std.testing.expectEqual(@as(u64, delivery_fence_capacity + 1), ui.delivery_admitted);
    try std.testing.expect(ui.draft != null);
    try std.testing.expectEqualStrings("not consumed", ui.records.items[ui.draft.?].body.items);
    try ui.pumpDisplay();
    try std.testing.expectEqualStrings("not consumed", ui.records.items[ui.draft.?].body.items);
}
test "synchronizing remote view never paints an idle prompt or invents a running task" {
    var fake = FakeRemote{ .snapshot = .{ .available = false, .attached = true, .control_epoch = 1 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    ui.adoptRemoteActivity(&fake.snapshot);
    try std.testing.expect(!ui.busy and ui.remoteSynchronizing());
    try std.testing.expect(!ui.settingsIdle());
    const before = try ui.prepareComposer(arena.allocator(), ui.connection.current(), 79);
    try std.testing.expect(!std.mem.endsWith(u8, before.decoration.plain, "> "));
    try typeDraft(&ui, "kept");
    try std.testing.expect(!try ui.remoteStart(fake.client(), .prompt, ui.editor.bytes.items));
    try std.testing.expectEqualStrings("kept", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
    try std.testing.expectEqualStrings("Synchronizing session; draft kept", ui.notice);
    ui.dirty = false;
    fake.snapshot.available = true;
    ui.adoptRemoteActivity(&fake.snapshot);
    try std.testing.expect(ui.dirty and !ui.busy and !ui.remoteSynchronizing());
    try std.testing.expectEqualStrings("Ready", ui.notice);
    const after = try ui.prepareComposer(arena.allocator(), ui.connection.current(), 79);
    try std.testing.expect(std.mem.endsWith(u8, after.decoration.plain, "> "));
}
test "terminal notice OOM backpressures buffered remote terminals and local launches" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    var items = [_]session_client.Item{
        try session_client.ownEvent(std.testing.allocator, 1, .{ .finished = .{ .status = .failed, .detail = error.TestFirstTerminal } }),
        try session_client.ownEvent(std.testing.allocator, 1, .{ .finished = .{ .status = .failed, .detail = error.TestSecondTerminal } }),
    };
    defer for (items[fake.buffered_index..]) |*item| item.deinit();
    for (&items, 1..) |*item, sequence| {
        item.delivery_epoch = 9;
        item.delivery_sequence = @intCast(sequence);
    }
    fake.buffered_items = &items;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    ui.allocator = failing.allocator();
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 1), fake.buffered_index);
    try std.testing.expect(ui.terminal_notice_pending != null and ui.terminal_delivery != null);
    try std.testing.expectEqual(error.TestFirstTerminal, ui.last_terminal.?.detail.?);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_admitted);
    try std.testing.expectEqual(@as(usize, 0), fake.ack_count);
    ui.retryTerminalNotice();
    try ui.pumpDisplay();
    try std.testing.expect(ui.terminal_notice_pending != null);
    try std.testing.expectEqual(@as(usize, 1), fake.buffered_index);
    try std.testing.expectEqual(@as(u64, 0), ui.delivery_admitted);
    for ([_][]const u8{ "ordinary draft", "!echo keep", "/compact" }) |draft| {
        ui.wipeEditor();
        try typeDraft(&ui, draft);
        try ui.submit();
        try std.testing.expectEqualStrings(draft, ui.editor.bytes.items);
        try std.testing.expectEqual(@as(usize, 0), fake.submits);
    }
    ui.allocator = std.testing.allocator;
    ui.retryTerminalNotice();
    try std.testing.expect(ui.terminal_notice_pending == null);
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 2), fake.buffered_index);
    try ui.pumpDisplay();
    try std.testing.expectEqual(error.TestSecondTerminal, ui.last_terminal.?.detail.?);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expect(std.mem.find(u8, ui.records.items[0].body.items, "TestFirstTerminal") != null);
    try std.testing.expect(std.mem.find(u8, ui.records.items[1].body.items, "TestSecondTerminal") != null);
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(u64, 2), fake.ack_sequence);

    var local_cancel: p.Cancellation = .{};
    var local_bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &local_cancel);
    defer local_bridge.deinit();
    var local = fixtureUi(&local_bridge, &local_cancel);
    defer local.deinit();
    _ = try local.inbox.enqueue(std.testing.allocator, .follow_up, "retained lease");
    local.terminal_notice_pending = .{ .status = .failed, .detail = error.TestFirstTerminal };
    try local.dispatchNext();
    try std.testing.expectEqual(@as(usize, 1), local.queueSnapshot().follow_up);
    try std.testing.expect(!local.busy and local.future == null);
}
test "remote display drains a bounded batch without polling empty pages or settling queued output" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 4 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    var items: [72]session_client.Item = undefined;
    var initialized: usize = 0;
    defer for (items[fake.buffered_index..initialized]) |*item| item.deinit();
    for (0..70) |index| {
        items[index] = try session_client.ownEvent(std.testing.allocator, 4, .{ .text = "x" });
        initialized += 1;
    }
    const body: [70]u8 = @splat('x');
    const blocks = [_]p.Block{.{ .text = &body }};
    items[70] = try session_client.ownEvent(std.testing.allocator, 4, .{ .assistant_committed = &blocks });
    initialized += 1;
    items[71] = try session_client.ownEvent(std.testing.allocator, 4, .{ .finished = (session_client.Terminal{ .status = .success }).toRuntime() });
    initialized += 1;
    fake.buffered_items = &items;
    // The owner has already finished, but queued live events still own display.
    fake.snapshot.busy = false;
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 64), fake.buffered_index);
    try std.testing.expectEqual(@as(usize, 64), ui.records.items[ui.draft.?].body.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.empty_polls);
    try std.testing.expect(ui.busy and ui.last_terminal == null);
    try std.testing.expectEqual(@as(u8, 0), ui.remote_idle_ticks);
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 72), fake.buffered_index);
    try std.testing.expectEqual(@as(usize, 0), fake.empty_polls);
    try ui.complete();
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqualStrings(&body, ui.records.items[ui.records.items.len - 1].body.items);
    // One empty tick makes just one adapter poll, not 64 synchronous RPCs.
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 1), fake.empty_polls);
}
test "remote deinit detaches and never cancels or clears the daemon task" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 4 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(u64, 4), ui.remote_epoch);
    ui.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.detaches);
    try std.testing.expectEqual(@as(usize, 0), fake.cancels);
    try std.testing.expectEqual(@as(usize, 0), fake.cancel_clears);
}
test "remote submit is sent once and a rejected submit keeps the draft and starts nothing" {
    var fake = FakeRemote{};
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try typeDraft(&ui, "hello");
    fake.submit_failure = error.Transport;
    try ui.submit();
    try std.testing.expectEqual(@as(usize, 1), fake.submits);
    try std.testing.expect(!ui.busy and ui.future == null);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expectEqualStrings("hello", ui.editor.bytes.items);
    try std.testing.expectEqualStrings("Connection lost; the task was not canceled", ui.notice);

    fake.submit_failure = null;
    try ui.submit();
    // Exactly one accepted request: no implicit retry of the rejected one.
    try std.testing.expectEqual(@as(usize, 2), fake.submits);
    try std.testing.expectEqual(@as(u64, 1), fake.last_submit_epoch);
    try std.testing.expectEqual(session_client.TaskKind.prompt, fake.last_submit_kind);
    try std.testing.expectEqualStrings("hello", fake.text[0..fake.text_len]);
    try std.testing.expect(ui.busy and ui.remote_kind == .prompt);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqualStrings("hello", ui.records.items[0].body.items);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);
}
test "remote approval binds the epoch that displayed it and bypasses the local bridge" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .permission = .{ .id = 11, .tool_name = "bash", .description = "rm -rf build" } });
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expect(ui.permission != null);
    try std.testing.expectEqual(@as(u64, 6), ui.permission.?.epoch);
    // Approvals are backend-owned: the local Bridge must not hold a pending id.
    try std.testing.expect(ui.bridge.pending == null);
    ui.decidePermission(.deny, false);
    try std.testing.expectEqual(@as(usize, 1), fake.approvals);
    try std.testing.expectEqual(@as(u64, 6), fake.last_approve_epoch);
    try std.testing.expectEqual(@as(u64, 11), fake.last_approve_id);
    try std.testing.expect(ui.permission == null);
}
test "configure success adopts current context and keeps later runtime updates" {
    try text.initLocale();
    const Case = struct { context: ?r.ContextSnapshot, label: []const u8, named: bool };
    const cases = [_]Case{
        .{ .context = .{ .tokens = 77, .limit = 100 }, .label = "77.0%", .named = false },
        .{ .context = .{ .tokens = 0, .limit = 100 }, .label = "0.0%", .named = true },
        .{ .context = .{ .tokens = 0, .limit = 100, .known = false }, .label = "?%", .named = false },
        .{ .context = null, .label = "?%", .named = true },
    };
    const old: ?r.ContextSnapshot = .{ .tokens = 25, .limit = 100 };
    for ([_]bool{ false, true }) |asynchronous| {
        for (cases) |case| {
            var actions: FakeAsync = .{};
            defer actions.deinit();
            var cancel: p.Cancellation = .{};
            var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
            defer bridge.deinit();
            var fixture: AuthFixture = .{ .initial_context = old, .context_after_save = case.context, .available_after_save = true };
            var ui = fixtureUi(&bridge, &cancel);
            defer ui.deinit();
            ui.connection = fixture.connection();
            ui.connection.configure_provider_fn = AuthFixture.configureProvider;
            if (asynchronous) ui.connection.async_actions = actions.channel();
            var screen: @import("../tests/regular_screen.zig").Screen = .{};
            try expectConfigureContextDraw(&ui, &screen, old, "25.0%");

            const provider: ?core_config.providers.Id = if (case.named) .deepseek else null;
            ui.beginSecret(provider);
            const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
            try ui.parser.feed("\x1b[200~sk-fixture-secret\x1b[201~", sink);
            try ui.parser.feed("\rsecret-tail", sink);
            if (asynchronous) {
                try std.testing.expect(ui.secret_mode and ui.secret.len == 0 and ui.hasAsync(.configure));
                try std.testing.expectEqualDeep(old, ui.display.context);
                try std.testing.expectEqual(@as(usize, 1), actions.next);
                const request = actions.requests[0].?;
                try std.testing.expectEqual(provider, request.action.configure.provider);
                try std.testing.expectEqualStrings("sk-fixture-secret", request.action.configure.key);
                // The owner publishes before the receipt; neither admission nor a
                // pending draw may replace the old display prematurely.
                fixture.initial_context = case.context;
                fixture.configured = true;
                if (case.context == null) {
                    // A canceled pasted-secret modal can still receive success.
                    try ui.parser.feed("\x03", sink);
                    try std.testing.expect(!ui.secret_mode and ui.secret_quarantine);
                }
                try ui.draw();
                try screen.replay(ui.frame);
                try std.testing.expectEqualDeep(old, ui.display.context);
                testAcknowledgeFullFrame(&ui);
                actions.complete(.none, null, false);
                ui.pumpAsync();
            } else try std.testing.expectEqual(@as(usize, 1), fixture.saves);

            // This assertion precedes draw: only a successful save/receipt adopts
            // the freshly published owner snapshot, including null or unknown.
            try std.testing.expectEqualDeep(case.context, ui.display.context);
            try std.testing.expect(configured(ui.connection.current()));
            try std.testing.expect(!ui.secret_mode and !ui.secret_quarantine and !ui.parser.secret);
            try std.testing.expect(ui.parser.stop_feed and ui.secret_provider == null);
            try std.testing.expectEqualStrings("", ui.editor.bytes.items);
            for (ui.secret.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
            try std.testing.expect(publishedNotice(&ui, if (case.named) "Key saved locally" else "Saved locally; send a message to connect"));
            try expectConfigureContextDraw(&ui, &screen, case.context, case.label);

            const host = bridge.host();
            const later = r.ContextSnapshot{ .tokens = 31, .limit = 200 };
            try host.emit_fn(host.context, .{ .context_snapshot = later }, &cancel);
            try drainBridge(&ui);
            try std.testing.expectEqualDeep(@as(?r.ContextSnapshot, later), ui.display.context);
            ui.display.seed(fixture.initial_context);
            try expectConfigureContextDraw(&ui, &screen, later, "15.5%");

            const usage = r.ContextSnapshot{ .tokens = 86, .limit = 200 };
            try host.emit_fn(host.context, .{ .usage = .{ .purpose = .normal, .protocol = .chat, .value = .{ .total_tokens = 86 } } }, &cancel);
            try drainBridge(&ui);
            try std.testing.expectEqualDeep(@as(?r.ContextSnapshot, usage), ui.display.context);
            ui.display.seed(fixture.initial_context);
            try expectConfigureContextDraw(&ui, &screen, usage, "43.0%");
        }
    }
}
test "failed or obsolete configure leaves the seeded context unchanged" {
    try text.initLocale();
    const old: ?r.ContextSnapshot = .{ .tokens = 25, .limit = 100 };
    const changed: ?r.ContextSnapshot = .{ .tokens = 77, .limit = 100 };
    // Local failure, rejected receipt, and superseded receipt respectively.
    for (0..3) |mode| {
        var actions: FakeAsync = .{};
        defer actions.deinit();
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var fixture: AuthFixture = .{ .initial_context = old, .context_after_save = changed, .fail = true };
        var ui = fixtureUi(&bridge, &cancel);
        defer ui.deinit();
        ui.connection = fixture.connection();
        if (mode != 0) ui.connection.async_actions = actions.channel();
        var screen: @import("../tests/regular_screen.zig").Screen = .{};
        try expectConfigureContextDraw(&ui, &screen, old, "25.0%");
        ui.beginSecret(null);
        // Deliberately make current() differ, so even an accidental refresh on
        // a failure or an obsolete receipt is observable.
        fixture.initial_context = changed;
        const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
        try ui.parser.feed("sk-fixture-secret\r", sink);
        if (mode != 0) {
            try std.testing.expectEqualDeep(old, ui.display.context);
            actions.complete(.none, if (mode == 1) error.FixtureSaveFailed else null, mode == 2);
            ui.pumpAsync();
            try std.testing.expect(!ui.hasAsync(.configure));
        }
        try std.testing.expectEqualDeep(old, ui.display.context);
        try std.testing.expect(!publishedNotice(&ui, "Saved locally"));
        if (mode == 2) {
            try std.testing.expect(ui.secret_mode); // Obsolete receipts do not close the modal.
            ui.endSecret();
        } else {
            try std.testing.expect(!ui.secret_mode);
            try std.testing.expectEqualStrings("Could not save configuration; use /login to retry", ui.notice);
        }
        try expectConfigureContextDraw(&ui, &screen, old, "25.0%");
    }
}
test "async effort completion flashes for five seconds" {
    var fixture: SelectionFixture = .{ .effort = .low };
    defer fixture.deinit();
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = fixture.connection();
    ui.connection.async_actions = actions.channel();
    try std.testing.expect(ui.beginAsync(.cycle_effort, .effort) != null);
    ui.clock_ms = 100;
    actions.complete(.{ .effort = .high }, null, false);
    ui.pumpAsync();
    try std.testing.expectEqual(shared.ReasoningEffort.high, ui.effort_flash.?.level);
    try std.testing.expectEqual(@as(u64, 5100), ui.effort_flash.?.until_ms);
    ui.clock_ms = 5099;
    ui.expireEffortFlash();
    try std.testing.expect(ui.effort_flash != null);
    ui.clock_ms = 5100;
    ui.expireEffortFlash();
    try std.testing.expect(ui.effort_flash == null);
}
test "multiple reserved async records survive intervening display records" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    for (0..4) |slot| {
        try ui.reserveRecord();
        const ticket = try FakeAsync.start(&actions, 6, .{ .submit = .{ .kind = .prompt, .text = "reserved" } });
        var record = Record{ .kind = .user };
        try record.append(std.testing.allocator, "reserved");
        ui.async_pending[slot] = .{
            .ticket = ticket,
            .purpose = .submit,
            .original_editor = try std.testing.allocator.dupe(u8, ""),
            .editor_revision = 0,
            .epoch = 6,
            .permission_id = null,
            .previous_effort = ui.connection.current().reasoning_effort,
            .settings_generation = 0,
            .stop_instance = 0,
            .record = record,
        };
        _ = try ui.add(.notice, "intervening event");
    }
    for (0..4) |_| {
        actions.complete(.none, null, false);
        ui.pumpAsync();
    }
    try std.testing.expectEqual(@as(usize, 8), ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 8), ui.record_index.count());
    for (ui.records.items, 0..) |record, index| try std.testing.expectEqual(index, ui.record_index.get(record.id).?);
}
test "busy async effort preserves same batch draft through late completion" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    ui.busy = true;
    ui.mode = .calling_model;
    ui.future = ui.io.async(struct {
        fn noop() void {}
    }.noop, .{});
    const body = try ui.add(.assistant, "streaming body");
    const tool = try ui.add(.tool, "tool body");
    ui.draft = body;
    const host = bridge.host();
    try host.emit_fn(host.context, .{ .context_snapshot = .{ .tokens = 12, .limit = 32768 } }, &cancel);
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    try ui.parser.feed("\x1b[Z/model rejected-busy\r", sink);
    try std.testing.expectEqualStrings("/model rejected-busy", ui.editor.bytes.items);
    try std.testing.expectEqualStrings("Only ordinary conversation text can be queued", ui.notice);
    try std.testing.expectEqual(@as(usize, 3), ui.records.items.len);
    try std.testing.expect(ui.records.items[2].kind == .notice);
    try std.testing.expectEqual(NoticeLevel.warning, ui.records.items[2].notice_level);
    try std.testing.expectEqualStrings("Only ordinary conversation text can be queued", ui.records.items[2].body.items);
    var screen: @import("../tests/regular_screen.zig").Screen = .{};
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(&ui);
    try std.testing.expectEqual(@as(usize, 1), screen.count("Only ordinary conversation text can be queued"));
    try std.testing.expectEqual(@as(?usize, body), ui.draft);
    try std.testing.expectEqual(@as(usize, 1), actions.next);
    try std.testing.expect(actions.requests[0].?.action == .cycle_effort);
    try std.testing.expect(ui.hasAsync(.effort));
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
    try std.testing.expectEqual(@as(usize, 0), fake.enqueues);
    const revision = ui.editor_revision;
    // A second shortcut is not admitted while the first ticket is outstanding.
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 1), actions.next);
    actions.complete(.{ .effort = .high }, null, false);
    ui.pumpAsync();
    try std.testing.expect(!ui.hasAsync(.effort));
    try std.testing.expectEqual(@as(usize, 3), ui.records.items.len);
    try std.testing.expectEqualStrings("/model rejected-busy", ui.editor.bytes.items);
    try std.testing.expectEqual(revision, ui.editor_revision);
    try std.testing.expect(ui.busy and ui.future != null);
    try std.testing.expectEqual(@as(?r.State, .calling_model), ui.mode);
    try std.testing.expectEqual(@as(?usize, body), ui.draft);
    try std.testing.expectEqualStrings("streaming body", ui.records.items[body].body.items);
    try std.testing.expectEqualStrings("tool body", ui.records.items[tool].body.items);
    var item = bridge.pop().?;
    item.deinit();
    // Actual task completion joins the future; it must not consume the draft.
    fake.snapshot.busy = false;
    try ui.complete();
    try std.testing.expect(!ui.busy and ui.future == null);
    try std.testing.expectEqualStrings("/model rejected-busy", ui.editor.bytes.items);
    try std.testing.expectEqual(revision, ui.editor_revision);
    try ui.parser.feed("!", sink);
    try std.testing.expectEqualStrings("/model rejected-busy!", ui.editor.bytes.items);
}
test "async input barrier remains for submit and effort guards" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    ui.busy = true;
    ui.editor_pasted = true;
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(@as(usize, 0), actions.next);
    ui.editor_pasted = false;
    try ui.parser.feed("\x1b[200~\x1b[Z\x1b[201~", sink);
    try std.testing.expectEqual(@as(usize, 0), actions.next);
    ui.wipeEditor();
    ui.secret_mode = true;
    ui.cycleEffort();
    try std.testing.expectEqual(@as(usize, 0), actions.next);
    ui.secret_mode = false;
    ui.secret_quarantine = true;
    try ui.parser.feed("\x1b[Z", sink);
    try std.testing.expectEqual(@as(usize, 0), actions.next);
    ui.secret_quarantine = false;
    ui.busy = false;
    try ui.parser.feed("hello\rdiscarded", sink);
    try std.testing.expectEqual(@as(usize, 1), actions.next);
    try std.testing.expect(actions.requests[0].?.action == .submit);
    try std.testing.expectEqualStrings("hello", ui.editor.bytes.items);
    try std.testing.expect(ui.parser.stop_feed);
}
test "async submit queues behind an effort probe without dropping Enter" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    try std.testing.expect(ui.beginAsync(.cycle_effort, .effort) != null);
    try typeDraft(&ui, "after probe");
    try ui.submit();
    try std.testing.expectEqual(@as(usize, 2), actions.next);
    try std.testing.expectEqualStrings("after probe", actions.requests[1].?.action.submit.text);
    actions.complete(.none, error.ThinkingCapabilitiesUnknown, false);
    ui.pumpAsync();
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    var users: usize = 0;
    var warnings: usize = 0;
    for (ui.records.items) |record| switch (record.kind) {
        .user => {
            users += 1;
            try std.testing.expectEqualStrings("after probe", record.body.items);
        },
        .notice => {
            warnings += 1;
            try std.testing.expectEqual(NoticeLevel.warning, record.notice_level);
            try std.testing.expect(std.mem.find(u8, record.body.items, "capabilities unknown") != null);
        },
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), users);
    try std.testing.expectEqual(@as(usize, 1), warnings);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("after probe", ui.input_history.entries.items[0]);
}
test "late cancel acknowledgements do not overwrite the terminal result" {
    for ([_]bool{ false, true }) |clear| {
        var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 6 } };
        var actions: FakeAsync = .{};
        defer actions.deinit();
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = remoteUi(&fake, &bridge, &cancel);
        defer ui.deinit();
        ui.connection.async_actions = actions.channel();
        try std.testing.expect(ui.beginAsync(if (clear) .{ .cancel_clear = 1 } else .cancel, if (clear) .cancel_clear else .cancel) != null);
        ui.last_terminal = .{ .status = .canceled, .detail = error.Canceled };
        ui.busy = false;
        ui.notice = "Canceled; prior side effects remain";
        actions.complete(.none, null, false);
        ui.pumpAsync();
        try std.testing.expectEqualStrings("Canceled; prior side effects remain", ui.notice);
    }
}
test "async metadata errors retain the actionable synchronous notice" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    try std.testing.expect(ui.beginAsync(.refresh_models, .refresh) != null);
    actions.complete(.none, error.NoOfficialProvider, false);
    ui.pumpAsync();
    try std.testing.expectEqualStrings("No official provider configured; use /login first", ui.notice);
    try std.testing.expect(ui.beginAsync(.cycle_effort, .effort) != null);
    actions.complete(.none, error.ThinkingCapabilitiesLoading, false);
    ui.pumpAsync();
    try std.testing.expectEqualStrings("Thinking capabilities are loading; try Shift+Tab again shortly", ui.notice);
}
test "async submit commits once after receipt and preserves newer draft" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    try typeDraft(&ui, "first prompt");
    try std.testing.expect(!try ui.remoteStart(fake.client(), .prompt, ui.editor.bytes.items));
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
    try std.testing.expect(!ui.busy);
    try std.testing.expect(ui.presentationWaiting());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pending_composer = try ui.prepareComposer(arena.allocator(), ui.connection.current(), 79);
    try std.testing.expect(!std.mem.endsWith(u8, pending_composer.decoration.plain, "> "));
    ui.wipeEditor();
    try typeDraft(&ui, "new draft");
    try std.testing.expectEqualStrings("first prompt", actions.requests[0].?.action.submit.text);
    actions.complete(.none, null, false);
    ui.pumpAsync();
    ui.pumpAsync();
    try std.testing.expect(!ui.presentationWaiting());
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqualStrings("first prompt", ui.records.items[0].body.items);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("new draft", ui.editor.bytes.items);
}
test "async refresh failure survives urgent approve success after notice OOM" {
    var fake = FakeRemote{};
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    ui.inject_epoch = 1;
    try ui.applyEvent(.{ .permission = .{ .id = 42, .tool_name = "bash", .description = "preview" } }, false, true);
    try std.testing.expect(ui.beginAsync(.refresh_models, .refresh) != null);
    ui.decidePermission(.deny, false);
    try std.testing.expect(ui.hasAsync(.approve));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    ui.allocator = failing.allocator();
    actions.complete(.none, error.NoOfficialProvider, false);
    ui.pumpAsync();
    try std.testing.expect(ui.notice_alias_pending != null);
    const failure_hash = ui.notice_alias_pending.?.hash;
    try std.testing.expectEqual(NoticeLevel.warning, ui.notice_alias_pending.?.level);
    ui.allocator = std.testing.allocator;
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expectEqual(failure_hash, ui.notice_alias_pending.?.hash);
    try std.testing.expectEqualStrings("No official provider configured; use /login first", ui.notice);
    try std.testing.expect(!ui.hasAsync(.refresh) and !ui.hasAsync(.approve));
    ui.observeAdvisories();
    try std.testing.expect(ui.notice_alias_pending == null);
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqualStrings("Request denied", ui.records.items[0].body.items);
    try std.testing.expectEqual(NoticeLevel.warning, ui.records.items[1].notice_level);
    try std.testing.expectEqualStrings("No official provider configured; use /login first", ui.records.items[1].body.items);
    ui.observeAdvisories();
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
}
test "async acceptance preserves identical text that was cleared and retyped" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    try typeDraft(&ui, "repeat this");
    try std.testing.expect(!try ui.remoteStart(fake.client(), .prompt, ui.editor.bytes.items));
    try Ui.key(&ui, .clear);
    try Ui.key(&ui, .{ .text = .{ .value = "repeat this", .pasted = false } });
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expectEqualStrings("repeat this", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
}
test "async rejected and obsolete submissions keep draft without publishing history" {
    const Case = struct { obsolete: bool, failure: ?anyerror };
    for ([_]Case{
        .{ .obsolete = false, .failure = error.Rejected },
        .{ .obsolete = true, .failure = null },
        .{ .obsolete = true, .failure = error.Rejected },
    }) |case| {
        var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
        var actions: FakeAsync = .{};
        defer actions.deinit();
        var cancel: p.Cancellation = .{};
        var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
        defer bridge.deinit();
        var ui = remoteUi(&fake, &bridge, &cancel);
        defer ui.deinit();
        ui.connection.async_actions = actions.channel();
        try typeDraft(&ui, "keep this");
        try std.testing.expect(!try ui.remoteStart(fake.client(), .prompt, ui.editor.bytes.items));
        actions.complete(.none, case.failure, case.obsolete);
        ui.pumpAsync();
        try std.testing.expectEqualStrings("keep this", ui.editor.bytes.items);
        try std.testing.expectEqual(@as(usize, if (case.obsolete) 0 else 1), ui.records.items.len);
        if (!case.obsolete) {
            try std.testing.expectEqual(Kind.notice, ui.records.items[0].kind);
            try std.testing.expectEqual(NoticeLevel.failure, ui.records.items[0].notice_level);
            try std.testing.expect(std.mem.find(u8, ui.records.items[0].body.items, "keep this") == null);
        }
        try std.testing.expectEqual(@as(usize, 0), ui.input_history.entries.items.len);
        try std.testing.expectEqual(@as(usize, 0), fake.submits);
        try std.testing.expect(ui.last_terminal == null);
        try std.testing.expect(!ui.normalAsyncPending());
        try std.testing.expect(!ui.busy);
    }
}
test "authoritative baseline replaces accepted user echo without erasing a new draft" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    _ = try ui.add(.notice, "startup banner");
    try std.testing.expect(try ui.remoteStart(fake.client(), .prompt, "accepted prompt"));
    try typeDraft(&ui, "next draft");
    var item = try session_client.ownEvent(std.testing.allocator, 6, .{ .user_committed = .{ .id = 1, .text = "accepted prompt" } });
    item.history_reset = true;
    item.history_display_reset = true;
    item.history_replay = true;
    fake.item = item;
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 2), ui.records.items.len);
    try std.testing.expectEqualStrings("startup banner", ui.records.items[0].body.items);
    try std.testing.expectEqualStrings("accepted prompt", ui.records.items[1].body.items);
    try std.testing.expectEqual(@as(usize, 1), ui.input_history.entries.items.len);
    try std.testing.expectEqualStrings("next draft", ui.editor.bytes.items);
}
test "async queue reply does not block body delivery or erase typeahead" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    try typeDraft(&ui, "queued message");
    try ui.enqueueDraft(.steering);
    try std.testing.expectEqual(@as(usize, 0), fake.enqueues);
    ui.wipeEditor();
    try typeDraft(&ui, "typeahead");
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .text = "live body" });
    try ui.pumpDisplay();
    try std.testing.expect(ui.draft != null);
    try std.testing.expectEqualStrings("live body", ui.records.items[ui.draft.?].body.items);
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expectEqualStrings("typeahead", ui.editor.bytes.items);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expect(publishedNotice(&ui, "Steering pending"));
}
test "late async approval cannot clear or relabel a newer permission" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 6 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .permission = .{ .id = 11, .tool_name = "bash", .description = "old request" } });
    try ui.pumpDisplay();
    ui.decidePermission(.deny, false);
    try std.testing.expectEqual(@as(usize, 0), fake.approvals);
    try std.testing.expect(ui.permission != null);
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .permission = .{ .id = 12, .tool_name = "bash", .description = "new request" } });
    try ui.pumpDisplay();
    ui.notice = "New request";
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expectEqual(@as(u64, 12), ui.permission.?.id);
    try std.testing.expectEqualStrings("New request", ui.notice);
}
test "remote queue sends bind the current epoch and are never launched locally" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.remote_kind = .prompt;
    try typeDraft(&ui, "please continue");
    try ui.enqueueDraft(.steering);
    try std.testing.expectEqual(@as(usize, 1), fake.enqueues);
    try std.testing.expectEqual(@as(u64, 6), fake.last_enqueue_epoch);
    try std.testing.expectEqual(session_client.QueueKind.steering, fake.last_enqueue_kind);
    try std.testing.expectEqualStrings("please continue", fake.text[0..fake.text_len]);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expect(publishedNotice(&ui, "Steering pending"));
    try std.testing.expectEqual(@as(usize, 0), ui.inbox.snapshot().steering);

    ui.busy = false;
    try ui.dispatchNext();
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
}
test "remote management commands run while busy instead of entering steering" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.remote_kind = .prompt;
    try typeDraft(&ui, "/ls --running");
    try ui.submit();
    try std.testing.expectEqual(@as(usize, 1), fake.manages);
    try std.testing.expectEqual(@as(?std.meta.Tag(session_client.Manage), .list), fake.last_manage);
    try std.testing.expectEqual(@as(usize, 0), fake.enqueues);
    try std.testing.expectEqual(@as(usize, 0), fake.submits);
    try std.testing.expectEqual(@as(usize, 0), ui.editor.bytes.items.len);

    // /attach runs before steering too and adopts the new owner snapshot.
    fake.manage_switched = true;
    fake.snapshot.busy = true;
    fake.snapshot.mode = .awaiting_permission;
    fake.snapshot.task_kind = .prompt;
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .text = "old session draft" });
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expect(ui.draft != null);
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .permission = .{ .id = 3, .tool_name = "bash", .description = "old approval" } });
    try ui.pumpRemote();
    try std.testing.expect(ui.permission != null);

    try typeDraft(&ui, "/attach --takeover session-b");
    try ui.submit();
    try std.testing.expectEqual(@as(usize, 2), fake.manages);
    try std.testing.expectEqual(@as(?std.meta.Tag(session_client.Manage), .attach), fake.last_manage);
    try std.testing.expectEqual(@as(usize, 0), fake.enqueues);
    try std.testing.expectEqual(@as(u64, 7), ui.remote_epoch);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
    try std.testing.expect(ui.draft == null);
    try std.testing.expect(ui.permission == null);
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(?r.State, .awaiting_permission), ui.mode);
}
test "remote committed flags survive direct application without bridge payload" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    for ([_]bool{ true, false }) |clipped| {
        try ui.appendDraft(.assistant, "remote-stream");
        const id = ui.records.items[ui.draft.?].id;
        fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .assistant_committed = &.{} });
        fake.item.?.display_truncated = clipped;
        fake.item.?.canonical_complete = clipped;
        try ui.pumpRemote();
        try std.testing.expect(ui.bridgeEmpty());
        const index = ui.record_index.get(id).?;
        try std.testing.expectEqualStrings("remote-stream", ui.records.items[index].body.items);
        try std.testing.expect(ui.records.items[index].clipped);
    }
}
test "remote terminal completes without a local future and marks the task idle once" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    ui.remote_kind = .prompt;
    ui.mode = .calling_model;
    try std.testing.expect(ui.future == null);
    fake.item = try session_client.ownEvent(std.testing.allocator, 6, .{ .finished = (session_client.Terminal{ .status = .success }).toRuntime() });
    try ui.pumpRemote();
    try std.testing.expect(ui.bridge.terminal != null);
    try ui.complete();
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expect(ui.bridge.terminal == null);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    // No second completion from a null future or an already consumed terminal.
    try std.testing.expect(ui.bridge.pop() == null);
}
test "remote lost terminal fallback settles only after two consecutive idle samples" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 8 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try std.testing.expect(ui.busy);
    const records_before = ui.records.items.len;
    // One idle sample is not enough, and it must leave the view busy.
    fake.snapshot.busy = false;
    try ui.pumpRemote();
    try std.testing.expect(ui.busy);
    try std.testing.expect(!ui.remote_terminal_wait);
    try std.testing.expectEqual(@as(u8, 1), ui.remote_idle_ticks);
    try std.testing.expect(ui.last_terminal == null);
    // The second consecutive idle sample settles the view without a success.
    try ui.pumpRemote();
    try std.testing.expect(!ui.busy);
    try std.testing.expect(!ui.remote_terminal_wait);
    try std.testing.expect(ui.mode == null);
    try std.testing.expectEqual(@as(u8, 0), ui.remote_idle_ticks);
    try std.testing.expect(ui.last_terminal == null);
    try std.testing.expectEqualStrings("Remote task ended without a terminal result; reattach to verify", ui.notice);
    try std.testing.expectEqual(records_before, ui.records.items.len);
}
test "remote idle fallback never settles without an observed busy sample" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 9 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try ui.pumpRemote();
    try ui.pumpRemote();
    try std.testing.expectEqual(@as(u8, 0), ui.remote_idle_ticks);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    // A local busy view alone is not evidence of remote activity either.
    ui.busy = true;
    ui.notice = "Calling model";
    try ui.pumpRemote();
    try ui.pumpRemote();
    try std.testing.expect(ui.busy);
    try std.testing.expectEqualStrings("Calling model", ui.notice);
}
test "remote idle fallback count resets when the backend reports busy again" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 10 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.snapshot.busy = false;
    try ui.pumpRemote();
    try std.testing.expectEqual(@as(u8, 1), ui.remote_idle_ticks);
    try std.testing.expect(ui.busy);
    // Busy again: the count restarts, so a single later idle cannot settle.
    fake.snapshot.busy = true;
    try ui.pumpRemote();
    try std.testing.expectEqual(@as(u8, 0), ui.remote_idle_ticks);
    try std.testing.expect(ui.busy);
    fake.snapshot.busy = false;
    try ui.pumpRemote();
    try std.testing.expect(ui.busy);
    try std.testing.expect(ui.last_terminal == null);
    try std.testing.expectEqualStrings("Attached; task is running", ui.notice);
    try ui.pumpRemote();
    try std.testing.expect(!ui.busy);
    try std.testing.expect(ui.last_terminal == null);
    try std.testing.expectEqualStrings("Remote task ended without a terminal result; reattach to verify", ui.notice);
}
test "remote idle fallback yields to a real terminal consumed by the normal path" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 11 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 11, .{ .finished = (session_client.Terminal{ .status = .success }).toRuntime() });
    try ui.pumpRemote();
    try std.testing.expect(ui.bridge.terminal != null);
    // Idle samples while the terminal is pending must not synthesize a fallback.
    fake.snapshot.busy = false;
    try ui.pumpRemote();
    try ui.pumpRemote();
    try std.testing.expect(ui.busy);
    try std.testing.expect(ui.last_terminal == null);
    try ui.complete();
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expect(ui.bridge.terminal == null);
    try std.testing.expectEqualStrings("Ready", ui.notice);
}
test "remote finished terminal is consumed from an idle local view without a future" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 12 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // The previous task already returned the view to idle. The second task can
    // start and finish between two client snapshots, so no busy sample exists,
    // yet its real terminal is already waiting in the Bridge.
    try std.testing.expect(!ui.busy and ui.future == null);
    ui.mode = .calling_model;
    fake.item = try session_client.ownEvent(std.testing.allocator, 12, .{ .finished = (session_client.Terminal{ .status = .success }).toRuntime() });
    try ui.pumpRemote();
    try std.testing.expect(ui.bridge.terminal != null);
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqual(@as(?r.State, .calling_model), ui.mode);
    // The loop's readiness helper, not a direct complete() call, must consume it.
    try ui.finishReadyTask();
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expect(ui.bridge.terminal == null);
    try std.testing.expect(ui.mode == null);
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    // Idempotent: no terminal is left to consume on a later tick.
    try ui.finishReadyTask();
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
}
test "remote decision diagnostic survives terminal copies and empty paused queue stays hidden" {
    var fake = FakeRemote{ .snapshot = .{
        .available = true,
        .attached = true,
        .control_epoch = 12,
        .queue_paused = true,
    } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    var diagnostic: @import("../core/decision.zig").Diagnostic = .{
        .stage = .http,
        .backend = .systemone,
        .operation = .command,
        .http_status = 403,
    };
    diagnostic.setError(error.DecisionUnavailable);
    fake.item = try session_client.ownEvent(std.testing.allocator, 12, .{ .finished = (session_client.Terminal{
        .status = .paused,
        .failure = .decision_unavailable,
        .decision_failure = diagnostic,
    }).toRuntime() });
    // Source reuse cannot mutate any queued diagnostic storage.
    diagnostic.setError(error.UnrelatedLaterFailure);
    try ui.pumpRemote();
    try ui.finishReadyTask();
    try std.testing.expectEqualStrings("DecisionUnavailable", ui.last_terminal.?.decision_failure.?.causeName());
    try std.testing.expect(ui.last_terminal.?.decision_failure.?.stage == .http);
    try std.testing.expectEqual(@as(?u16, 403), ui.last_terminal.?.decision_failure.?.http_status);
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    try std.testing.expectEqual(Kind.notice, ui.records.items[0].kind);
    try std.testing.expectEqual(NoticeLevel.failure, ui.records.items[0].notice_level);
    try std.testing.expectEqualStrings("Paused: decision review failed [HTTP 403]; operation not executed", ui.records.items[0].body.items);
    ui.notice = "Ready";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const line = try ui.footerHint(arena.allocator(), ui.connection.current());
    try std.testing.expectEqualStrings("", line);
    try std.testing.expect(ui.queueSnapshot().paused);
    ui.observeAdvisories();
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    fake.snapshot.follow_up = 1;
    try std.testing.expectEqualStrings("S:0 F:1 paused (/queue resume)", try ui.footerHint(arena.allocator(), ui.connection.current()));
}
test "handled remote terminal keeps the busy composer until ordered owner idle" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .mode = .calling_model, .control_epoch = 14 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try std.testing.expect(ui.busy and ui.remote_observed_busy);
    fake.item = try session_client.ownEvent(std.testing.allocator, 14, .{ .finished = (session_client.Terminal{ .status = .canceled, .failure = .canceled }).toRuntime() });
    try ui.pumpRemote();
    try ui.finishReadyTask();
    // The terminal is handled while the owner still reports this task busy, so
    // no idle composer or settings-idle state is published and the result holds.
    try std.testing.expect(ui.busy);
    try std.testing.expect(ui.remote_terminal_wait);
    try std.testing.expect(!ui.settingsIdle());
    try std.testing.expect(ui.mode == null);
    try std.testing.expectEqual(r.Status.canceled, ui.last_terminal.?.status);
    try std.testing.expectEqual(error.Canceled, ui.last_terminal.?.detail.?);
    try std.testing.expectEqualStrings("Canceled; prior side effects remain", ui.notice);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const held = try ui.prepareComposer(arena.allocator(), ui.connection.current(), 79);
    try std.testing.expect(!std.mem.endsWith(u8, held.decoration.plain, "> "));
    // Ordered owner idle releases the held view without inventing a missing
    // terminal or discarding the real result and its exact failure detail.
    ui.dirty = false;
    fake.snapshot.busy = false;
    try ui.pumpRemote();
    try std.testing.expect(ui.busy and ui.remote_terminal_wait);
    try std.testing.expectEqualStrings("Canceled; prior side effects remain", ui.notice);
    try ui.pumpRemote();
    try std.testing.expect(!ui.busy);
    try std.testing.expect(!ui.remote_terminal_wait);
    try std.testing.expect(ui.mode == null);
    try std.testing.expectEqual(@as(u8, 0), ui.remote_idle_ticks);
    try std.testing.expect(ui.dirty);
    try std.testing.expect(ui.settingsIdle());
    try std.testing.expectEqual(r.Status.canceled, ui.last_terminal.?.status);
    try std.testing.expectEqual(error.Canceled, ui.last_terminal.?.detail.?);
    try std.testing.expectEqualStrings("Canceled; prior side effects remain", ui.notice);
}
test "one display batch settles a terminal before the next task state and text" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .mode = .calling_model, .control_epoch = 15 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try std.testing.expect(ui.busy);
    var items: [3]session_client.Item = undefined;
    var initialized: usize = 0;
    defer for (items[fake.buffered_index..initialized]) |*item| item.deinit();
    items[0] = try session_client.ownEvent(std.testing.allocator, 15, .{ .finished = (session_client.Terminal{ .status = .canceled, .failure = .canceled }).toRuntime() });
    initialized += 1;
    items[1] = try session_client.ownEvent(std.testing.allocator, 15, .{ .state = .awaiting_permission });
    initialized += 1;
    items[2] = try session_client.ownEvent(std.testing.allocator, 15, .{ .text = "second task" });
    initialized += 1;
    fake.buffered_items = &items;
    fake.snapshot.task_kind = .command;
    // finished(task 1), state(task 2) and text(task 2) share one bounded batch:
    // the terminal must settle first, and the ordered state then adopts task 2.
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 3), fake.buffered_index);
    try std.testing.expect(!ui.remote_terminal_wait);
    try std.testing.expect(ui.last_terminal == null);
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(?r.State, .awaiting_permission), ui.mode);
    try std.testing.expectEqual(session_client.TaskKind.command, ui.remote_kind);
    try std.testing.expectEqualStrings("Attached; task is running", ui.notice);
    // Task 2's body is live content, not task 1's interrupted residue.
    try std.testing.expect(ui.draft != null);
    try std.testing.expectEqualStrings("second task", ui.records.items[ui.draft.?].body.items);
    try std.testing.expect(!ui.records.items[ui.draft.?].interrupted);
}
test "one display batch starts a next task after a terminal when the owner already reports idle" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 18 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try std.testing.expect(!ui.busy);
    var items: [3]session_client.Item = undefined;
    var initialized: usize = 0;
    defer for (items[fake.buffered_index..initialized]) |*item| item.deinit();
    items[0] = try session_client.ownEvent(std.testing.allocator, 18, .{ .finished = (session_client.Terminal{ .status = .success }).toRuntime() });
    initialized += 1;
    items[1] = try session_client.ownEvent(std.testing.allocator, 18, .{ .state = .executing_tool });
    initialized += 1;
    items[2] = try session_client.ownEvent(std.testing.allocator, 18, .{ .text = "next task" });
    initialized += 1;
    fake.buffered_items = &items;
    fake.snapshot.task_kind = .command;
    // The terminal settles against an already-idle owner view, and the ordered
    // state in the same batch is still the next task, not task 1 residue.
    try ui.pumpDisplay();
    try std.testing.expectEqual(@as(usize, 3), fake.buffered_index);
    try std.testing.expect(ui.last_terminal == null);
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(?r.State, .executing_tool), ui.mode);
    try std.testing.expectEqual(session_client.TaskKind.command, ui.remote_kind);
    try std.testing.expectEqualStrings("Attached; task is running", ui.notice);
    try std.testing.expect(!std.mem.eql(u8, ui.notice, "Remote task ended without a terminal result; reattach to verify"));
    try std.testing.expect(ui.draft != null);
    try std.testing.expectEqualStrings("next task", ui.records.items[ui.draft.?].body.items);
    try std.testing.expect(!ui.records.items[ui.draft.?].interrupted);
}
test "late cancel acknowledgement cannot replace a result awaiting owner idle" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .mode = .calling_model, .control_epoch = 17 } };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    fake.item = try session_client.ownEvent(std.testing.allocator, 17, .{ .finished = (session_client.Terminal{ .status = .failed, .failure = .transport }).toRuntime() });
    try ui.pumpRemote();
    try ui.finishReadyTask();
    try std.testing.expect(ui.busy and ui.remote_terminal_wait);
    try std.testing.expectEqualStrings("Failed", ui.notice);
    // The user's late cancellation still travels to the owner, but its receipt
    // must not replace the handled result while ordered idle is still pending.
    try std.testing.expect(ui.beginAsync(.cancel, .cancel) != null);
    try std.testing.expectEqualStrings("Waiting for session...", ui.notice);
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expectEqualStrings("Failed", ui.notice);
    try std.testing.expect(ui.busy and ui.remote_terminal_wait);
    try std.testing.expectEqual(r.Status.failed, ui.last_terminal.?.status);
    try std.testing.expectEqual(error.Transport, ui.last_terminal.?.detail.?);
    // Ordered idle then releases the view and keeps the same result.
    fake.snapshot.busy = false;
    try ui.pumpRemote();
    try ui.pumpRemote();
    try std.testing.expect(!ui.busy);
    try std.testing.expectEqualStrings("Failed", ui.notice);
    try std.testing.expectEqual(r.Status.failed, ui.last_terminal.?.status);
}
test "remote owner still busy keeps the handled result until ordered next-task state" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .mode = .calling_model, .control_epoch = 13 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    // Task 1: the owner stays busy while its terminal arrives, so the view keeps
    // the busy composer instead of painting an idle prompt it would re-busy.
    try std.testing.expect(ui.busy and ui.remote_observed_busy);
    fake.item = try session_client.ownEvent(std.testing.allocator, 13, .{ .finished = (session_client.Terminal{ .status = .success }).toRuntime() });
    try ui.pumpRemote();
    try ui.finishReadyTask();
    try std.testing.expect(ui.busy);
    try std.testing.expect(ui.remote_terminal_wait);
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expect(ui.remote_observed_busy);
    // A bare busy snapshot proves neither ordering nor a next task.
    fake.snapshot.task_kind = .command;
    try ui.pumpRemote();
    try std.testing.expect(ui.remote_terminal_wait);
    try std.testing.expectEqual(r.Status.success, ui.last_terminal.?.status);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    // An ordered state event is the next task: it ends the wait and adopts it
    // from the current owner snapshot rather than from a busy boolean edge.
    fake.item = try session_client.ownEvent(std.testing.allocator, 13, .{ .state = .calling_model });
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expect(!ui.remote_terminal_wait);
    try std.testing.expect(ui.last_terminal == null);
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(?r.State, .calling_model), ui.mode);
    try std.testing.expectEqual(session_client.TaskKind.command, ui.remote_kind);
    try std.testing.expectEqualStrings("Attached; task is running", ui.notice);
}
test "startup attach restores a running partial stream and pending approval" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .mode = .awaiting_permission, .control_epoch = 3 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    try std.testing.expect(ui.busy);
    try std.testing.expectEqual(@as(?r.State, .awaiting_permission), ui.mode);
    fake.item = try session_client.ownEvent(std.testing.allocator, 3, .{ .text = "partial answer" });
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expect(ui.draft != null);
    try std.testing.expectEqualStrings("partial answer", ui.records.items[0].body.items);
    fake.item = try session_client.ownEvent(std.testing.allocator, 3, .{ .permission = .{ .id = 5, .tool_name = "bash", .description = "pending approval" } });
    try ui.pumpRemote();
    try std.testing.expect(ui.permission != null);
    try std.testing.expectEqual(@as(u64, 3), ui.permission.?.epoch);
    try std.testing.expectEqualStrings("pending approval", ui.permission.?.description);
}
test "deltas from a replaced control epoch are dropped before display" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6 } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    fake.item = try session_client.ownEvent(std.testing.allocator, 5, .{ .text = "stale controller output" });
    try ui.pumpRemote();
    try drainBridge(&ui);
    try std.testing.expect(ui.draft == null);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
}
test "remote busy close requires confirmation before any backend close or steering" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 2, .session_id = @splat(0) } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.remote_kind = .prompt;
    const current = "0000000000000000000000000000000000000000000000000000000000000000";
    try typeDraft(&ui, "/close " ++ current);
    try ui.submit();
    // Busy and attached: nothing is sent yet; the ACKed popup owns the decision.
    try std.testing.expectEqual(@as(usize, 0), fake.manages);
    try std.testing.expectEqual(@as(usize, 0), fake.enqueues);
    try std.testing.expect(ui.stop_open);
    try std.testing.expect(ui.stop_close != null);
    try std.testing.expectEqualStrings(current, ui.stop_close.?);

    // The typed --force form is an explicit confirmation and skips the popup.
    ui.closeStop();
    try typeDraft(&ui, "/close --force " ++ current);
    try ui.submit();
    try std.testing.expectEqual(@as(usize, 1), fake.manages);
    try std.testing.expectEqual(@as(?std.meta.Tag(session_client.Manage), .close), fake.last_manage);
    try std.testing.expectEqual(@as(usize, 0), fake.enqueues);
    try std.testing.expect(!ui.stop_open);
}
test "remote stop gates the owner first and authorizes the adopted queue revision" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 5, .queue_revision = 11, .session_id = @splat(1) } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.remote_kind = .prompt;
    try std.testing.expectEqual(@as(u64, 11), ui.stopIdentity().revision);
    try Ui.key(&ui, .cancel);
    try std.testing.expect(ui.stop_open and !ui.stop_danger);
    // Exactly one owner request, before the modal exists, and the adopted
    // snapshot (revision 12) is what the identity authorizes against.
    try std.testing.expectEqual(@as(usize, 1), fake.confirmings);
    try std.testing.expect(fake.last_confirming_active);
    try std.testing.expectEqual(@as(u64, 5), fake.last_confirming_epoch);
    try std.testing.expectEqual(@as(u64, 12), fake.last_confirming_revision);
    try std.testing.expectEqual(@as(u64, 12), ui.stop_identity.?.revision);
    try std.testing.expect(ui.queueSnapshot().confirming);
    // Esc releases the barrier without asking the owner to clear the queue.
    try Ui.key(&ui, .escape);
    try std.testing.expectEqual(@as(usize, 2), fake.confirmings);
    try std.testing.expect(!fake.last_confirming_active);
    try std.testing.expectEqual(@as(usize, 0), fake.cancel_clears);
    try std.testing.expect(!ui.stop_open and ui.stop_identity == null);
}
test "remote stop requested for a replaced owner is never unbound by a late close" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .busy = true, .control_epoch = 5, .queue_revision = 3, .session_id = @splat(2) } };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.remote_kind = .prompt;
    try Ui.key(&ui, .cancel);
    try std.testing.expectEqual(@as(usize, 1), fake.confirmings);
    // A takeover replaced the epoch and also ended the busy task: the revision
    // and busy changes alone must not stop Esc from releasing the old barrier.
    fake.snapshot.control_epoch = 6;
    fake.snapshot.busy = false;
    ui.remote_epoch = 6;
    ui.busy = false;
    try Ui.key(&ui, .escape);
    try std.testing.expectEqual(@as(usize, 1), fake.confirmings);
    try std.testing.expect(!ui.stop_open);

    // Opening a modal and losing the owner before Esc must also stay silent.
    fake.snapshot.busy = true;
    ui.busy = true;
    try Ui.key(&ui, .cancel);
    try std.testing.expectEqual(@as(usize, 2), fake.confirmings);
    fake.snapshot.control_epoch = 7;
    fake.snapshot.session_id = @splat(3);
    ui.remote_epoch = 7;
    try Ui.key(&ui, .escape);
    try std.testing.expectEqual(@as(usize, 2), fake.confirmings);
    try std.testing.expect(!ui.stop_open);
}
test "Codex device login binds generation and publishes success once" {
    const Owner = struct {
        state: Connection.State = .{ .runtime = null, .model = "", .base_url = "" },
        starts: usize = 0,
        cancels: usize = 0,
        canceled_generation: u64 = 0,
        fn current(raw: *anyopaque) Connection.State {
            return @as(*@This(), @ptrCast(@alignCast(raw))).state;
        }
        fn configure(_: *anyopaque, _: []const u8) !void {}
        fn login(raw: *anyopaque, action: corecodex.Action, generation: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (action) {
                .start => {
                    self.starts += 1;
                    try std.testing.expectEqual(@as(u64, 0), generation);
                },
                .cancel => {
                    self.cancels += 1;
                    self.canceled_generation = generation;
                },
            }
        }
    };
    var owner: Owner = .{};
    owner.state.codex_login = .{ .generation = 4, .status = .succeeded };
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.connection = .{ .context = &owner, .current_fn = Owner.current, .configure_fn = Owner.configure, .codex_login_fn = Owner.login };
    ui.startCodexLogin();
    try std.testing.expect(ui.codex_open and ui.codex_generation == null and owner.starts == 1);
    ui.observeCodexLogin(); // Previous success cannot complete the new attempt.
    try std.testing.expect(ui.codex_open and ui.records.items.len == 0);
    owner.state.codex_login = .{ .generation = 5, .status = .pending };
    @memcpy(owner.state.codex_login.code[0..7], "ABC-123");
    owner.state.codex_login.code_len = 7;
    ui.observeCodexLogin();
    try std.testing.expectEqual(@as(?u64, 5), ui.codex_generation);
    ui.dirty = false;
    ui.display_changed = false;
    ui.observeCodexLogin();
    try std.testing.expect(!ui.dirty and !ui.display_changed);
    try ui.draw();
    try std.testing.expect(std.mem.find(u8, ui.frame, corecodex.verification_url) != null);
    try std.testing.expect(std.mem.find(u8, ui.frame, "ABC-123") != null);
    discardFixtureFrame(&ui);
    owner.state.codex_login = .{ .generation = 4, .status = .succeeded };
    ui.observeCodexLogin();
    try std.testing.expect(ui.codex_open);
    owner.state.codex_login = .{ .generation = 5, .status = .succeeded };
    ui.observeCodexLogin();
    try std.testing.expect(!ui.codex_open and ui.records.items.len == 1);
    try std.testing.expectEqualStrings("OpenAI Codex connected", ui.records.items[0].body.items);
    ui.observeCodexLogin();
    try std.testing.expectEqual(@as(usize, 1), ui.records.items.len);
    ui.startCodexLogin();
    ui.cancelCodexLogin(); // Wait for the new generation before canceling.
    try std.testing.expectEqual(@as(usize, 0), owner.cancels);
    owner.state.codex_login = .{ .generation = 6, .status = .pending };
    ui.observeCodexLogin();
    try std.testing.expect(!ui.codex_open and owner.cancels == 1 and owner.canceled_generation == 6);

    // Picker confirmation requires a completely acknowledged fresh frame.
    ui.openProviderPicker();
    for (ui.provider_choices.items[0..ui.provider_choices.len], 0..) |choice, index| {
        if (choice == .provider and choice.provider == .openai_codex) ui.provider_picker.selected = index;
    }
    try ui.providerKey(.enter);
    try std.testing.expectEqual(@as(usize, 2), owner.starts);
    ui.provider_picker.markPaste();
    try ui.providerKey(.enter);
    try std.testing.expectEqual(@as(usize, 2), owner.starts);
    ui.provider_picker.clear();
    try ui.draw();
    try ui.providerKey(.enter); // pending frame does not authorize
    try std.testing.expectEqual(@as(usize, 2), owner.starts);
    testAcknowledgeFullFrame(&ui);
    try ui.providerKey(.enter);
    try std.testing.expect(ui.codex_open and !ui.secret_mode and owner.starts == 3);
    owner.state.codex_login = .{ .generation = 7, .status = .pending };
    ui.observeCodexLogin();
    try Ui.key(&ui, .escape);
    try std.testing.expectEqual(@as(u64, 7), owner.canceled_generation);
    _ = try ui.editor.insert("/login openai-codex");
    try ui.submit();
    try std.testing.expect(ui.codex_open and !ui.secret_mode and owner.starts == 4);
}
test "remote codex login opens only after the owner receipt and cancels its exact generation" {
    var fake = FakeRemote{ .snapshot = .{ .available = true, .attached = true, .control_epoch = 6, .session_id = @splat(3) } };
    // A previous completed login must never open or complete the next attempt.
    fake.codex = .{ .generation = 4, .status = .succeeded };
    var actions: FakeAsync = .{};
    defer actions.deinit();
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = remoteUi(&fake, &bridge, &cancel);
    defer ui.deinit();
    ui.connection.async_actions = actions.channel();
    ui.startCodexLogin();
    // Queue admission is not owner acceptance: no panel, no bound generation.
    try std.testing.expect(ui.codex_opening and !ui.codex_open and ui.codex_generation == null);
    try std.testing.expectEqual(@as(usize, 1), actions.next);
    try std.testing.expectEqual(corecodex.Action.start, actions.requests[0].?.action.codex_login.action);
    try std.testing.expectEqual(@as(u64, 0), actions.requests[0].?.action.codex_login.generation);
    ui.observeCodexLogin();
    try std.testing.expect(!ui.codex_open and ui.records.items.len == 0);

    // Esc before the receipt defers cancellation instead of guessing a generation.
    try Ui.key(&ui, .escape);
    try std.testing.expect(ui.codex_cancel_waiting and !ui.codex_open);
    try std.testing.expectEqual(@as(usize, 1), actions.next);

    // The owner accepts the start and publishes the pending attempt; the
    // deferred Esc then travels as a typed cancel for that exact generation.
    fake.codex = .{ .generation = 5, .status = .pending };
    @memcpy(fake.codex.code[0..7], "ABC-123");
    fake.codex.code_len = 7;
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expect(ui.codex_open and ui.codex_generation == 5);
    try std.testing.expect(ui.presentationWaiting());
    try std.testing.expectEqual(@as(usize, 2), actions.next);
    try std.testing.expectEqual(corecodex.Action.cancel, actions.requests[1].?.action.codex_login.action);
    try std.testing.expectEqual(@as(u64, 5), actions.requests[1].?.action.codex_login.generation);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);

    // Another generation's success is not this attempt's success.
    fake.codex = .{ .generation = 6, .status = .succeeded };
    ui.observeCodexLogin();
    try std.testing.expect(ui.codex_open and ui.codex_generation == 5);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);

    // A rejected cancel keeps both the panel and its generation.
    actions.complete(.none, error.Transport, false);
    ui.pumpAsync();
    try std.testing.expect(ui.codex_open and ui.codex_generation == 5);
    try std.testing.expectEqualStrings("Could not cancel OpenAI Codex login", ui.notice);

    // Cancel admission is not closure either: only the receipt for THIS
    // generation closes the panel, and it never publishes a success.
    fake.codex = .{ .generation = 5, .status = .pending };
    try Ui.key(&ui, .escape);
    try std.testing.expectEqual(@as(usize, 3), actions.next);
    try std.testing.expect(ui.codex_open and ui.codex_generation == 5);
    actions.complete(.none, null, false);
    ui.pumpAsync();
    try std.testing.expect(!ui.codex_open and ui.codex_generation == null);
    try std.testing.expect(!ui.presentationWaiting());
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);

    // A rejected start clears the opening state and never shows a panel.
    ui.startCodexLogin();
    try std.testing.expect(ui.codex_opening and !ui.codex_open);
    actions.complete(.none, error.PublicationUnavailable, false);
    ui.pumpAsync();
    try std.testing.expect(!ui.codex_opening and !ui.codex_open and ui.codex_generation == null);
    try std.testing.expectEqualStrings("OpenAI Codex device login unavailable", ui.notice);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);

    // A superseded receipt retires the placeholder without a stale success.
    ui.startCodexLogin();
    try std.testing.expect(ui.codex_opening and !ui.codex_open);
    actions.complete(.none, null, true);
    ui.pumpAsync();
    try std.testing.expect(!ui.codex_opening and !ui.codex_open and ui.codex_generation == null);
    try std.testing.expectEqualStrings("Ready", ui.notice);
    try std.testing.expectEqual(@as(usize, 0), ui.records.items.len);
}
test "local stop keeps gating the UI inbox without a remote barrier request" {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    ui.busy = true;
    try Ui.key(&ui, .cancel);
    try std.testing.expect(ui.stop_open and ui.inbox.snapshot().confirming);
    try Ui.key(&ui, .escape);
    try std.testing.expect(!ui.stop_open and !ui.inbox.snapshot().confirming);
    try std.testing.expect(!cancel.isRequested());
}

/// Replay one owned history-page item exactly as the client delivers it, so
/// history coverage exercises the real resume path instead of a projection.
fn replayItem(ui: *Ui, a: std.mem.Allocator, event: r.Event) !void {
    var item = session_client.Item{ .event = event, .history_replay = true, .storage = &.{}, .allocator = a };
    defer item.deinit();
    ui.inject_epoch = item.epoch;
    ui.adoptReplayHistory(&item);
    ui.applying_history = true;
    defer ui.applying_history = false;
    try ui.applyEvent(item.event, item.display_truncated, item.canonical_complete);
}

fn replayToolName(messages: []const p.Message, index: usize, call_id: []const u8) []const u8 {
    for (messages[0..index]) |prior| for (prior.blocks) |candidate| {
        if (candidate == .tool_call and std.mem.eql(u8, candidate.tool_call.id, call_id)) return candidate.tool_call.name;
    };
    return "";
}

/// Replay saved canonical messages as the worker's seed pass does.
fn replayMessages(ui: *Ui, a: std.mem.Allocator, messages: []const p.Message) !void {
    var tool_id: u64 = 0;
    for (messages, 0..) |message, index| switch (message.role) {
        .context => {},
        .user => for (message.blocks) |block| switch (block) {
            .text => |value| try replayItem(ui, a, .{ .user_committed = .{ .id = 0, .text = value } }),
            else => {},
        },
        .assistant => {
            var calls: [8]p.Block = undefined;
            var count: usize = 0;
            var note = false;
            for (message.blocks) |block| switch (block) {
                .tool_call => if (count < calls.len) {
                    calls[count] = block;
                    count += 1;
                },
                .text => |value| note = note or std.mem.eql(u8, value, r.local_command_note),
                else => {},
            };
            const blocks = if (note and count != 0) calls[0..count] else message.blocks;
            if (blocks.len == 0) continue;
            try replayItem(ui, a, .{ .assistant_committed = blocks });
        },
        .tool => for (message.blocks) |block| switch (block) {
            .tool_result => |result| {
                tool_id +%= 1;
                try replayItem(ui, a, .{ .tool_result = .{
                    .id = tool_id,
                    .name = replayToolName(messages, index, result.call_id),
                    .local = r.isLocalCommand(result.call_id),
                    .result = .{
                        .text = result.text,
                        .is_error = result.is_error,
                        .canceled = result.canceled,
                        .truncated = result.truncated,
                    },
                } });
            },
            else => {},
        },
    };
}
