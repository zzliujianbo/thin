const FixtureConnection = struct {
    fn current(_: *anyopaque) Connection.State {
        return .{ .runtime = null, .model = "fixture", .base_url = "http://localhost/fixture" };
    }

    fn configuredCurrent(_: *anyopaque) Connection.State {
        return .{ .runtime = null, .available = true, .model = "fixture", .base_url = "http://localhost/fixture" };
    }

    fn configure(_: *anyopaque, _: []const u8) !void {
        return error.FixtureNotConfigured;
    }
};

fn fixtureUi(bridge: *bridge_module.Bridge, cancel: *p.Cancellation) Ui {
    return .{ .allocator = std.testing.allocator, .io = std.testing.io, .connection = .{ .context = bridge, .current_fn = FixtureConnection.current, .configure_fn = FixtureConnection.configure }, .bridge = bridge, .cancel = cancel, .terminal = undefined, .editor = .{ .allocator = std.testing.allocator }, .job = .{ .runtime = undefined, .cancel = cancel, .prompt = "" }, .size = .{ .columns = 80, .rows = 24 } };
}

fn testAcknowledgeFullFrame(ui: *Ui) void {
    ui.frame_offset = ui.frame.len;
    ui.finishFrame();
}

fn publishedNotice(ui: *const Ui, needle: []const u8) bool {
    var index = ui.records.items.len;
    while (index > 0) {
        index -= 1;
        const record = ui.records.items[index];
        if (record.kind != .notice) continue;
        if (std.mem.find(u8, record.body.items, needle) != null) return true;
    }
    return false;
}

fn seedPriorBottom(screen: *@import("../tests/regular_screen.zig").Screen) !void {
    for (0..screen.rows - 1) |_| try screen.replay("\r\n");
    try std.testing.expectEqual(screen.rows - 1, screen.row);
}

fn rowStartingWith(screen: *const @import("../tests/regular_screen.zig").Screen, prefix: []const u8) !usize {
    for (screen.grid, 0..) |line, row| if (std.mem.startsWith(u8, &line, prefix)) return row;
    return error.MissingRowPrefix;
}

fn expectLongWarningAdjacent(screen: *const @import("../tests/regular_screen.zig").Screen, composer_rows: usize, columns: usize) !void {
    const warning = "Saved thinking level not applied: model capabilities unknown";
    const status_row = screen.rows - composer_rows - 1;
    const clipped = warning[0..@min(warning.len, columns - 1)];
    try std.testing.expectEqualStrings(clipped, std.mem.trimEnd(u8, screen.grid[status_row][0..columns], " "));
    // The one-shot action result is now a conversation row, not footer text.
    try std.testing.expectEqual(@as(usize, 1), screen.count("Could not save thinking option"));
    const composer_row = try rowStartingWith(screen, "(fixture-old) ");
    try std.testing.expectEqual(status_row + 1, composer_row);
    try std.testing.expectEqual(@as(usize, 1), screen.count("(fixture-old) "));
}

fn idleEnterAllocationScenario(a: std.mem.Allocator) !void {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    try ui.draw();
    testAcknowledgeFullFrame(&ui);
    try Ui.key(&ui, .enter);
    _ = try ui.editor.insert("draft survives OOM");
    ui.allocator = a;
    ui.draw() catch |err| {
        try std.testing.expectEqual(@as(u16, 1), ui.idle_breaks);
        try std.testing.expectEqualStrings("draft survives OOM", ui.editor.bytes.items);
        try std.testing.expect(ui.frame.len == 0 and ui.frame_idle_breaks == 0);
        return if (err == error.WriteFailed) error.OutOfMemory else err;
    };
    testAcknowledgeFullFrame(&ui);
}

fn expectTranscriptGap(screen: *const @import("../tests/regular_screen.zig").Screen, before: []const u8, after: []const u8) !void {
    var first: ?usize = null;
    var second: ?usize = null;
    for (0..screen.history_len + screen.grid.len) |i| {
        const line = if (i < screen.history_len) &screen.history[i] else &screen.grid[i - screen.history_len];
        if (first == null and std.mem.indexOf(u8, line, before) != null) first = i;
        if (second == null and std.mem.indexOf(u8, line, after) != null) second = i;
    }
    try std.testing.expect(first != null and second != null);
    try std.testing.expectEqual(first.? + 2, second.?);
    const gap = first.? + 1;
    const line = if (gap < screen.history_len) &screen.history[gap] else &screen.grid[gap - screen.history_len];
    for (line) |byte| try std.testing.expectEqual(@as(u8, ' '), byte);
}

fn composerHistoryAllocationScenario(a: std.mem.Allocator) !void {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    ui.allocator = a;
    ui.editor.allocator = a;
    defer ui.deinit();
    ui.input_history.commit(a, try ui.input_history.prepare(a, "submitted"));
    _ = try ui.editor.insert("unsent draft");
    ui.editor.cursor = 0;
    ui.editor_pasted = true;
    ui.navigateInput(false) catch |err| {
        try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
        try std.testing.expectEqual(@as(usize, 0), ui.editor.cursor);
        try std.testing.expect(ui.editor_pasted and ui.history_draft == null and ui.input_history.index == null);
        return err;
    };
    try std.testing.expectEqualStrings("submitted", ui.editor.bytes.items);
    try ui.navigateInput(true);
    try std.testing.expectEqualStrings("unsent draft", ui.editor.bytes.items);
    try std.testing.expect(ui.editor_pasted);
}

fn composerHistoryEditAllocationScenario(a: std.mem.Allocator) !void {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    ui.allocator = a;
    ui.editor.allocator = a;
    defer ui.deinit();
    ui.input_history.commit(a, try ui.input_history.prepare(a, "submitted"));
    _ = try ui.editor.insert("pasted draft");
    ui.editor.cursor = 0;
    ui.editor_pasted = true;
    try ui.navigateInput(false);
    Ui.key(&ui, .{ .text = .{ .value = "x", .pasted = false } }) catch |err| {
        try std.testing.expectEqualStrings("submitted", ui.editor.bytes.items);
        try std.testing.expect(ui.input_history.index != null);
        try std.testing.expect(ui.history_draft != null and ui.history_draft_pasted);
        return err;
    };
    try std.testing.expectEqualStrings("xsubmitted", ui.editor.bytes.items);
    try std.testing.expect(ui.input_history.index == null and ui.history_draft == null);
}

fn plainWidthRows(a: std.mem.Allocator, columns: usize, body: []const u8, out: *std.ArrayList([]u8)) !void {
    const writer_module = @import("markdown_writer.zig");
    const display_text = @import("../util/display_text.zig");
    const clean = try display_text.sanitize(a, body, 1 << 20);
    defer a.free(clean);
    var w: writer_module.Writer = .{ .a = a, .columns = std.math.clamp(columns, 1, 512), .ansi = true, .base = .thinking };
    defer w.deinit();
    try w.emit(clean);
    try w.finish();
    for (w.lines.items) |row| try out.append(a, try a.dupe(u8, row));
}

fn expectTailMatchesPlain(tail: *plain_tail.Tail, columns: usize, body: []const u8) !void {
    const a = std.testing.allocator;
    var want: std.ArrayList([]u8) = .empty;
    defer {
        for (want.items) |row| a.free(row);
        want.deinit(a);
    }
    try plainWidthRows(a, columns, body, &want);
    var snap = try tail.snapshot(a);
    defer snap.deinit(a);
    const count = @min(tail.keepRows(), want.items.len);
    try std.testing.expectEqual(count, snap.rows.len);
    const expected = want.items[want.items.len - count ..];
    for (expected, snap.rows) |e, got| try std.testing.expectEqualStrings(e, got);
}

fn emitToolUi(ui: *Ui, event_: r.Event) !void {
    const host = ui.bridge.host();
    try host.emit_fn(host.context, event_, ui.cancel);
    var item = ui.bridge.pop() orelse return error.MissingToolUiEvent;
    defer item.deinit();
    try ui.event(item);
}

fn replayToolFrame(ui: *Ui, screen: *@import("../tests/regular_screen.zig").Screen) !void {
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(ui);
}

fn expectSynchronizedFrame(bytes: []const u8) !void {
    const begin = "\x1b[?2026h";
    const end = "\x1b[?2026l";
    try std.testing.expect(std.mem.startsWith(u8, bytes, begin));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, begin));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, end));
    // Cursor-show remains the final ACK marker, after the display is released.
    try std.testing.expect(std.mem.endsWith(u8, bytes, end ++ "\x1b[?25h"));
}

fn seedShiftDraft(ui: *Ui) !void {
    try ui.appendDraft(.assistant, "```\n");
    for (0..35) |row_index| {
        var buffer: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&buffer, "stream-row-{d:0>3} abcdefghijklmnopqrstuvwxyz abcdefghijklmnop\n", .{row_index});
        try ui.appendDraft(.assistant, line);
    }
}

fn nativeLine(screen: *const @import("../tests/regular_screen.zig").Screen, index: usize) []const u8 {
    return if (index < screen.history_len) &screen.history[index] else &screen.grid[index - screen.history_len];
}

fn testPlainRow(a: std.mem.Allocator, line: []const u8) ![]u8 {
    var plain: std.ArrayList(u8) = .empty;
    errdefer plain.deinit(a);
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            i += 2;
            while (i < line.len and line[i] != 'm') : (i += 1) {}
            if (i == line.len) return error.InvalidSgr;
            i += 1;
        } else {
            try plain.append(a, line[i]);
            i += 1;
        }
    }
    return plain.toOwnedSlice(a);
}

fn testNativePrefix(ui: *Ui, expected: []const []const u8, at: *usize) !void {
    var pos = ui.frame_clear_end;
    const count = ui.frame_records[0].stream_rows;
    for (ui.records.items[ui.records.items.len - 1].lines[0..count]) |line| {
        var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer encoded.deinit();
        try putStyled(&encoded.writer, 1, line);
        try encoded.writer.writeAll("\r\n");
        try std.testing.expect(pos + encoded.written().len <= ui.frame.len);
        try std.testing.expectEqualStrings(encoded.written(), ui.frame[pos..][0..encoded.written().len]);
        pos += encoded.written().len;
        try std.testing.expect(at.* < expected.len);
        const actual_plain = try testPlainRow(std.testing.allocator, line);
        defer std.testing.allocator.free(actual_plain);
        const expected_plain = try testPlainRow(std.testing.allocator, expected[at.*]);
        defer std.testing.allocator.free(expected_plain);
        try std.testing.expectEqualStrings(expected_plain, actual_plain);
        at.* += 1;
    }
}

fn testLongCanonicalSource(a: std.mem.Allocator, newline: bool) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(a);
    for (0..800) |i| {
        var buf: [64]u8 = undefined;
        try source.appendSlice(a, try std.fmt.bufPrint(&buf, "W{d:0>4} abc中文 **bold** xyz ", .{i + 1}));
    }
    if (newline) try source.append(a, '\n');
    return source.toOwnedSlice(a);
}

fn discardFixtureFrame(ui: *Ui) void {
    // Test-only discard of an unsent preview, NOT an acknowledgement. Legacy
    // tests freed only frame_arena; candidates now own a separate arena too.
    ui.discardFrameRecords(ui.frame_records);
    ui.frame_records = &.{};
    if (ui.frame_arena) |*arena| arena.deinit();
    if (ui.frame_tail_snapshot) |*snapshot| snapshot.deinit();
    if (ui.frame_menu_history) |*history| history.deinit();
    ui.frame_menu_history = null;
    ui.frame_arena = null;
    ui.frame_tail_snapshot = null;
    ui.frame_sparse = false;
    ui.frame_offset = 0;
    ui.frame = "";
    for (ui.records.items) |*record| record.discardPendingFlow();
}

fn seedCompactAckedTail(ui: *Ui, screen: *@import("../tests/regular_screen.zig").Screen) !void {
    _ = try ui.add(.user, "canon-a");
    _ = try ui.add(.user, "canon-b1\ncanon-b2\ncanon-b3\ncanon-b4\ncanon-b5\ncanon-b6");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(ui);
    _ = try ui.add(.user, "canon-c1\ncanon-c2\ncanon-c3\ncanon-c4\ncanon-c5\ncanon-c6\ncanon-c7\ncanon-c8\ncanon-c9\ncanon-c10\ncanon-c11\ncanon-c12\ncanon-c13");
    try ui.draw();
    try screen.replay(ui.frame);
    testAcknowledgeFullFrame(ui);
}

fn tailAllocationDraw(ui: *Ui) !void {
    // draw writes only to std.Io.Writer.Allocating, never terminal I/O. Its
    // drain translates allocator OOM to WriteFailed; the fault-test helper
    // requires the original allocation error. Do not alter production errors.
    ui.draw() catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
}

fn tailAllocationScenario(a: std.mem.Allocator, native: bool) !void {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    ui.allocator = a;
    ui.editor.allocator = a;
    defer ui.deinit();
    if (native) try seedShiftDraft(&ui) else try ui.appendDraft(.assistant, "| K | V |\n| --- | --- |\n| old | body |\n");
    try tailAllocationDraw(&ui);
    testAcknowledgeFullFrame(&ui);
    const old_ack = ui.tail_snapshot.?.full;
    const prefix_count = if (ui.records.items[ui.draft.?].flow_prefix) |prefix| prefix.rowCount() else 0;
    try ui.appendDraft(.assistant, if (native) "stream-row-035 more body\n" else "| new | cell |\n");
    tailAllocationDraw(&ui) catch |err| {
        // A failed candidate cannot replace/free the last acknowledged bytes.
        try std.testing.expectEqualStrings(old_ack, ui.tail_snapshot.?.full);
        const record = &ui.records.items[ui.draft.?];
        try std.testing.expectEqual(prefix_count, if (record.flow_prefix) |prefix| prefix.rowCount() else 0);
        try std.testing.expect(record.pending_flow_prefix == null and !record.pending_flow_change);
        try std.testing.expect(ui.frame.len == 0 and ui.frame_tail_snapshot == null);
        return err;
    };
    ui.resize(.{ .columns = 40, .rows = 12 });
    ui.finishFrame();
    try tailAllocationDraw(&ui);
    testAcknowledgeFullFrame(&ui);
}

fn reasoningTailAllocationScenario(a: std.mem.Allocator) !void {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(a, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    ui.allocator = a;
    ui.editor.allocator = a;
    defer ui.deinit();
    try ui.appendDraft(.reasoning, "alpha 中文\nbeta\n");
    tailAllocationDraw(&ui) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    testAcknowledgeFullFrame(&ui);
    try ui.appendDraft(.reasoning, "gamma-delta");
    ui.resize(.{ .columns = 20, .rows = 12 });
    tailAllocationDraw(&ui) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    testAcknowledgeFullFrame(&ui);
    ui.discardReasoning();
    tailAllocationDraw(&ui) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    testAcknowledgeFullFrame(&ui);
}

const SelectionFixture = struct {
    name: []const u8 = "fixture-old",
    owned: ?[]u8 = null,
    limit: u32 = 32768,
    low_price_input: bool = false,
    settings_notice: ?[]const u8 = null,
    effort: shared.ReasoningEffort = .off,
    levels: shared.activity.EffortSet = .{ .mask = 0x3f },
    selections: usize = 0,
    cycles: usize = 0,
    provider_saves: usize = 0,
    saved_provider: ?core_config.providers.Id = null,
    provider_hint: ?core_config.providers.Id = null,
    configured_providers: u8 = 0,
    profiles_override: ?[]const core_config.Model = null,
    model_providers: []const ModelProvider = &.{.{ .name = "fixture", .allow_custom = true }},
    disabled_models: []const bool = &.{},
    refreshes: usize = 0,
    metadata_changed: bool = false,
    pending_default: ?shared.ReasoningEffort = null,
    metadata_effort: ?shared.ReasoningEffort = null,
    key_matched: bool = false,
    fail: bool = false,
    proxy_configured: bool = false,
    proxy_list: [8][]const u8 = @splat(""),
    proxy_len: usize = 0,
    proxy_saves: usize = 0,
    proxy_fail: bool = false,
    proxy_last: ?[]const u8 = null,
    proxy_last_enabled: bool = false,
    /// Owner-published endpoint; members and endpoint are independent.
    proxy_address: ?[]const u8 = null,
    proxy_port: u16 = 0,
    proxy_address_buf: [253]u8 = undefined,
    proxy_endpoint: [core_config.max_proxy_endpoint_bytes]u8 = undefined,
    proxy_endpoint_len: usize = 0,
    proxy_address_saves: usize = 0,
    proxy_address_fail: bool = false,
    const profiles = [_]core_config.Model{.{ .name = "fixture/fixture-next", .context_tokens = 65536 }};
    /// Owner-side proxy list mutation: the UI never edits its own copy.
    fn proxyToggle(raw: *anyopaque, name: []const u8, enabled: bool) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.proxy_saves += 1;
        self.proxy_last = name;
        self.proxy_last_enabled = enabled;
        if (self.proxy_fail) return error.TestSelectionFailure;
        var index: usize = 0;
        while (index < self.proxy_len) : (index += 1) {
            if (std.mem.eql(u8, self.proxy_list[index], name)) break;
        }
        if (enabled) {
            if (index == self.proxy_len and self.proxy_len < self.proxy_list.len) {
                self.proxy_list[self.proxy_len] = name;
                self.proxy_len += 1;
            }
        } else if (index < self.proxy_len) {
            std.mem.copyForwards([]const u8, self.proxy_list[index..self.proxy_len], self.proxy_list[index + 1 .. self.proxy_len]);
            self.proxy_len -= 1;
        }
    }
    /// Owner-side endpoint mutation: parse, own the host bytes, publish. A
    /// failed save leaves the previous endpoint and members untouched. An empty
    /// value removes the whole proxy like the backend: the member list is
    /// dropped too, and no state survives for the next session.
    fn proxyEndpoint(raw: *anyopaque, value: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.proxy_address_saves += 1;
        if (value.len > self.proxy_endpoint.len) return error.TestSelectionFailure;
        @memcpy(self.proxy_endpoint[0..value.len], value);
        self.proxy_endpoint_len = value.len;
        if (self.proxy_address_fail) return error.TestSelectionFailure;
        self.proxy_address = null;
        self.proxy_port = 0;
        self.proxy_configured = false;
        if (value.len == 0) {
            for (self.proxy_list[0..self.proxy_len]) |*entry| entry.* = "";
            self.proxy_len = 0;
            return;
        }
        const parsed = (try core_config.parseProxyEndpoint(value)).?;
        if (parsed.address.len > self.proxy_address_buf.len) return error.TestSelectionFailure;
        @memcpy(self.proxy_address_buf[0..parsed.address.len], parsed.address);
        self.proxy_address = self.proxy_address_buf[0..parsed.address.len];
        self.proxy_port = parsed.port;
        self.proxy_configured = true;
    }
    fn refreshMetadata(ctx: *anyopaque) !void {
        const self: *SelectionFixture = @ptrCast(@alignCast(ctx));
        self.refreshes += 1;
    }
    fn pollMetadata(ctx: *anyopaque, idle: bool) bool {
        const self: *SelectionFixture = @ptrCast(@alignCast(ctx));
        if (!idle or !self.metadata_changed) return false;
        self.metadata_changed = false;
        if (self.metadata_effort) |level| {
            self.effort = level;
            self.levels = .{ .mask = 0x7f };
            self.pending_default = null;
        }
        return true;
    }
    fn connection(self: *@This()) Connection {
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .select_model_fn = select, .set_effort_fn = setEffort, .proxy_fn = proxyToggle, .proxy_address_fn = proxyEndpoint };
    }
    fn current(raw: *anyopaque) Connection.State {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return .{ .runtime = null, .model = self.name, .selection_name = if (std.mem.eql(u8, self.name, "fixture-old")) "fixture/fixture-old" else if (std.mem.eql(u8, self.name, "fixture-next")) "fixture/fixture-next" else self.name, .models = self.profiles_override orelse &profiles, .model_providers = self.model_providers, .model_disabled = self.disabled_models, .provider = self.provider_hint, .configured_providers = self.configured_providers, .context_limit = self.limit, .low_price_input = self.low_price_input, .settings_notice = self.settings_notice, .initial_context = .{ .tokens = 1000, .limit = self.limit }, .base_url = "http://localhost/unused", .reasoning_effort = self.effort, .effort_levels = self.levels, .pending_default_effort = self.pending_default, .proxy_configured = self.proxy_configured, .proxy_address = self.proxy_address, .proxy_port = self.proxy_port, .proxy_models = self.proxy_list[0..self.proxy_len] };
    }
    fn configure(_: *anyopaque, _: []const u8) !void {
        return error.TestSelectionOnly;
    }
    fn configureProvider(raw: *anyopaque, id: core_config.providers.Id, key: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.fail) return error.TestSelectionFailure;
        self.key_matched = std.mem.eql(u8, key, "fake-ui-key");
        self.saved_provider = id;
        self.configured_providers |= @as(u8, 1) << @intCast(@backingInt(id));
        self.provider_saves += 1;
    }
    fn select(raw: *anyopaque, name: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.fail) return error.TestSelectionFailure;
        const local = if (std.mem.startsWith(u8, name, "fixture/")) name["fixture/".len..] else name;
        const copy = try std.testing.allocator.dupe(u8, local);
        if (self.owned) |old| std.testing.allocator.free(old);
        self.owned = copy;
        self.name = copy;
        self.selections += 1;
        if (std.mem.eql(u8, copy, "fixture-next")) self.limit = 65536;
    }
    fn setEffort(raw: *anyopaque, effort: shared.ReasoningEffort) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.fail) return error.TestSelectionFailure;
        self.effort = effort;
        self.cycles += 1;
    }
    fn deinit(self: *@This()) void {
        if (self.owned) |name| std.testing.allocator.free(name);
    }
};

const ImageModelFixture = struct {
    const profiles = [_]core_config.Model{
        .{ .name = "login/deepseek-flash", .protocol = .chat, .context_tokens = 16384 },
        .{ .name = "unlogged/deepseek-flash", .protocol = .chat, .context_tokens = 16384 },
    };
    state: Connection.State = .{ .runtime = null, .model = "primary", .base_url = "", .image_models = &profiles, .decision_models = &DecisionModelFixture.profiles, .model_providers = &DecisionModelFixture.logged, .decision_enabled = true, .decision_model = "login/family/judge" },
    calls: usize = 0,
    decision_calls: usize = 0,
    fail: bool = false,
    fn current(raw: *anyopaque) Connection.State {
        return @as(*@This(), @ptrCast(@alignCast(raw))).state;
    }
    fn configure(_: *anyopaque, _: []const u8) !void {}
    fn image(raw: *anyopaque, choice: Connection.DecisionChoice) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.fail) return error.SaveFailed;
        self.state.image_enabled = choice != .off;
        self.state.image_model = switch (choice) {
            .off => null,
            .model => "login/deepseek-flash",
        };
        if (choice == .model) try std.testing.expectEqualStrings("login/deepseek-flash", choice.model);
    }
    fn decision(raw: *anyopaque, _: Connection.DecisionChoice) !void {
        @as(*@This(), @ptrCast(@alignCast(raw))).decision_calls += 1;
    }
    fn connection(self: *@This()) Connection {
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .image_fn = image, .decision_fn = decision };
    }
};

const DecisionModelFixture = struct {
    const profiles = [_]core_config.Model{
        .{ .name = "login/family/judge", .protocol = .chat, .context_tokens = 16384 },
        .{ .name = "second/family/judge", .protocol = .chat, .context_tokens = 16384 },
        .{ .name = "unlogged/private-model", .protocol = .chat, .context_tokens = 16384 },
    };
    const logged = [_]ModelProvider{.{ .name = "login" }};
    const other = [_]ModelProvider{.{ .name = "second" }};
    state: Connection.State = .{ .runtime = null, .model = "primary", .selection_name = "main/primary", .base_url = "", .decision_models = &profiles, .model_providers = &logged },
    calls: usize = 0,
    main_calls: usize = 0,
    fail: bool = false,
    saved: [1089]u8 = undefined,
    saved_len: usize = 0,
    fn current(raw: *anyopaque) Connection.State {
        return @as(*@This(), @ptrCast(@alignCast(raw))).state;
    }
    fn configure(_: *anyopaque, _: []const u8) !void {}
    fn mainSelect(raw: *anyopaque, _: []const u8) !void {
        @as(*@This(), @ptrCast(@alignCast(raw))).main_calls += 1;
        return error.UnexpectedMainSelection;
    }
    fn choose(raw: *anyopaque, choice: Connection.DecisionChoice) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.fail) return error.SaveFailed;
        const name = switch (choice) {
            .model => |value| value,
            else => return error.UnexpectedBackend,
        };
        @memcpy(self.saved[0..name.len], name);
        self.saved_len = name.len;
        self.state.decision_model = self.saved[0..name.len];
        self.state.decision_enabled = true;
    }
    fn connection(self: *@This()) Connection {
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .select_model_fn = mainSelect, .decision_fn = choose };
    }
};

const PreferenceFixture = struct {
    state: Connection.State = .{ .runtime = null, .model = "unchanged-primary", .base_url = "" },
    calls: usize = 0,
    fail: bool = false,
    fn current(raw: *anyopaque) Connection.State {
        return @as(*@This(), @ptrCast(@alignCast(raw))).state;
    }
    fn configure(_: *anyopaque, _: []const u8) !void {}
    fn save(raw: *anyopaque, key_: preference.Key, value: ?u32) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.fail) return error.SaveFailed;
        switch (key_) {
            .compaction_enabled => self.state.limits.compaction_enabled = value.? == 1,
            .memory_auto => self.state.memory_auto = value.? == 1,
            .command_timeout_ms => self.state.limits.command_timeout_ms = value.?,
            .request_timeout_ms => self.state.limits.request_timeout_ms = value.?,
        }
    }
    fn connection(self: *@This()) Connection {
        return .{ .context = self, .current_fn = current, .configure_fn = configure, .preference_fn = save };
    }
};

fn preferenceOption(picker: settings_value_module.Picker, value: ?u32) !usize {
    for (0..picker.count()) |index| {
        if (picker.isCustom(index)) continue;
        const candidate = picker.chosen(index) catch continue;
        if (candidate == value) return index;
    }
    return error.MissingPreferenceOption;
}

fn customPreferenceOption(picker: settings_value_module.Picker) !usize {
    for (0..picker.count()) |index| if (picker.isCustom(index)) return index;
    return error.MissingCustomOption;
}

const AuthFixture = struct {
    runtime: ?*r.Runtime = null,
    configured: bool = false,
    fail: bool = false,
    saves: usize = 0,
    calls: usize = 0,
    normal_calls: usize = 0,
    summary_calls: usize = 0,
    initial_context: ?r.ContextSnapshot = null,
    context_after_save: ?r.ContextSnapshot = null,
    available_after_save: bool = false,

    fn connection(self: *AuthFixture) Connection {
        return .{ .context = self, .current_fn = current, .configure_fn = configure };
    }

    fn current(ctx: *anyopaque) Connection.State {
        const self: *AuthFixture = @ptrCast(@alignCast(ctx));
        return .{ .runtime = if (self.configured) self.runtime else null, .available = self.configured and self.available_after_save, .model = "fixture-model", .base_url = "http://localhost/fixture", .initial_context = self.initial_context };
    }

    fn configure(ctx: *anyopaque, key_bytes: []const u8) !void {
        const self: *AuthFixture = @ptrCast(@alignCast(ctx));
        try std.testing.expectEqualStrings("sk-fixture-secret", key_bytes);
        self.saves += 1;
        if (self.fail) return error.FixtureSaveFailed;
        self.configured = true;
        self.initial_context = self.context_after_save;
    }

    fn configureProvider(ctx: *anyopaque, _: core_config.providers.Id, key_bytes: []const u8) !void {
        try configure(ctx, key_bytes);
    }

    fn call(ctx: *anyopaque, _: std.mem.Allocator, request: p.Request, _: p.ModelSink) !p.Outcome {
        const self: *AuthFixture = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (request.purpose == .summary) self.summary_calls += 1 else self.normal_calls += 1;
        return .{ .success = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "fixture done" }} }, .finish = .stop } };
    }

    fn prepare(_: *anyopaque, _: std.mem.Allocator, _: p.ToolCall) !r.Prepared {
        return error.UnexpectedTool;
    }

    fn execute(_: *anyopaque, _: std.mem.Allocator, _: r.Prepared, _: *const p.Cancellation) !r.Execution {
        return error.UnexpectedTool;
    }
};

fn pasteTailEscapeRegression(parts: []const []const u8, reset_before_timeout: bool) !void {
    var cancel: p.Cancellation = .{};
    var bridge = bridge_module.Bridge.init(std.testing.allocator, std.testing.io, &cancel);
    defer bridge.deinit();
    var ui = fixtureUi(&bridge, &cancel);
    defer ui.deinit();
    const id = try ui.inbox.enqueue(std.testing.allocator, .follow_up, "pending followup");
    const sink = input.Sink{ .context = &ui, .emit_fn = Ui.key };
    for (parts) |part| try ui.parser.feed(part, sink);
    try std.testing.expect(!ui.parser.pasted and ui.parser.escape_len == 1);
    if (reset_before_timeout) try ui.parser.feed("", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expectEqual(@as(?u64, id), ui.inbox.snapshot().newest_id);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), ui.parser.escape_len);
    // A rejected Escape is consumed, not left to revive on a later read/timer.
    try ui.parser.feed("", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expectEqual(@as(?u64, id), ui.inbox.snapshot().newest_id);
    try std.testing.expectEqualStrings("", ui.editor.bytes.items);
    try ui.parser.feed("\x1b", sink);
    try ui.parser.expireEscape(sink);
    try std.testing.expect(ui.inbox.snapshot().newest_id == null);
    try std.testing.expectEqualStrings("pending followup", ui.editor.bytes.items);
    try std.testing.expect(!cancel.isRequested());
}

const FakeRemote = struct {
    snapshot: session_client.Snapshot = .{ .available = true, .attached = true, .control_epoch = 1 },
    /// Owner-published device-login view; display-only, never credentials.
    codex: corecodex.View = .{},
    item: ?session_client.Item = null,
    buffered_items: []session_client.Item = &.{},
    buffered_index: usize = 0,
    empty_polls: usize = 0,
    submits: usize = 0,
    last_submit_epoch: u64 = 0,
    last_submit_kind: session_client.TaskKind = .prompt,
    text: [64]u8 = @splat(0),
    text_len: usize = 0,
    cancels: usize = 0,
    cancel_clears: usize = 0,
    last_cancel_clear_revision: u64 = 0,
    confirmings: usize = 0,
    last_confirming_epoch: u64 = 0,
    last_confirming_active: bool = false,
    last_confirming_revision: u64 = 0,
    detaches: usize = 0,
    approvals: usize = 0,
    last_approve_epoch: u64 = 0,
    last_approve_id: u64 = 0,
    enqueues: usize = 0,
    last_enqueue_epoch: u64 = 0,
    last_enqueue_kind: session_client.QueueKind = .steering,
    resumes: usize = 0,
    manages: usize = 0,
    last_manage: ?std.meta.Tag(session_client.Manage) = null,
    manage_switched: bool = false,
    manage_exit: bool = false,
    manage_failure: ?anyerror = null,
    saved_fixture: ?[]const session_client.SavedSession = null,
    submit_failure: ?anyerror = null,
    ack_failure: bool = false,
    ack_count: usize = 0,
    ack_epoch: u64 = 0,
    ack_sequence: u64 = 0,
    /// Exact intervals handed to the selective range channel, in order.
    ack_ranges: [64]struct { first: u64, last: u64 } = @splat(.{ .first = 0, .last = 0 }),
    ack_range_count: usize = 0,
    ack_range_failure: bool = false,
    ack_range_epoch: u64 = 0,

    fn acknowledgeFn(ctx: *anyopaque, epoch: u64, sequence: u64) anyerror!void {
        const self = from(ctx);
        if (self.ack_failure) return error.QueueFull;
        self.ack_count += 1;
        self.ack_epoch = epoch;
        self.ack_sequence = sequence;
    }

    fn acknowledgeRangeFn(ctx: *anyopaque, epoch: u64, first: u64, last: u64) anyerror!void {
        const self = from(ctx);
        // Prefix acks (first == 0) are legacy acknowledge semantics.
        if (first == 0) return acknowledgeFn(ctx, epoch, last);
        if (self.ack_range_failure) return error.QueueFull;
        if (first == 0 or first > last) return error.InvalidSequence;
        self.ack_range_epoch = epoch;
        if (self.ack_range_count < self.ack_ranges.len) {
            self.ack_ranges[self.ack_range_count] = .{ .first = first, .last = last };
            self.ack_range_count += 1;
        }
    }

    fn client(self: *FakeRemote) session_client.Client {
        return .{ .context = self, .vtable = &vtable };
    }

    fn record(self: *FakeRemote, value: []const u8) void {
        self.text_len = @min(value.len, self.text.len);
        @memcpy(self.text[0..self.text_len], value[0..self.text_len]);
    }

    fn from(ctx: *anyopaque) *FakeRemote {
        return @ptrCast(@alignCast(ctx));
    }

    fn snapshotFn(ctx: *anyopaque) *const session_client.Snapshot {
        return &from(ctx).snapshot;
    }
    fn submitFn(ctx: *anyopaque, epoch: u64, kind: session_client.TaskKind, value: []const u8) anyerror!void {
        const self = from(ctx);
        self.submits += 1;
        self.last_submit_epoch = epoch;
        self.last_submit_kind = kind;
        self.record(value);
        if (self.submit_failure) |err| return err;
    }
    fn pollFn(ctx: *anyopaque, _: std.mem.Allocator) anyerror!?session_client.Item {
        const self = from(ctx);
        if (self.item) |value| {
            self.item = null;
            return value;
        }
        if (self.buffered_index < self.buffered_items.len) {
            const value = self.buffered_items[self.buffered_index];
            self.buffered_index += 1;
            return value;
        }
        self.empty_polls += 1;
        return null;
    }
    fn bufferedFn(ctx: *anyopaque) bool {
        const self = from(ctx);
        return self.item != null or self.buffered_index < self.buffered_items.len;
    }
    fn cancelFn(ctx: *anyopaque, _: u64) anyerror!void {
        from(ctx).cancels += 1;
    }
    fn cancelClearFn(ctx: *anyopaque, _: u64, revision: u64) anyerror!void {
        const self = from(ctx);
        self.cancel_clears += 1;
        self.last_cancel_clear_revision = revision;
    }
    fn setConfirmingFn(ctx: *anyopaque, epoch: u64, active: bool) anyerror!void {
        const self = from(ctx);
        self.confirmings += 1;
        self.last_confirming_epoch = epoch;
        self.last_confirming_active = active;
        // The owner adopts a complete fresh snapshot on every barrier change;
        // only the queue revision matters here, so the UI must rebuild its stop
        // identity from the adopted value instead of a pre-RPC sample.
        self.snapshot.queue_revision +%= 1;
        self.last_confirming_revision = self.snapshot.queue_revision;
    }
    fn approveFn(ctx: *anyopaque, epoch: u64, id: u64, _: r.Decision) anyerror!void {
        const self = from(ctx);
        self.approvals += 1;
        self.last_approve_epoch = epoch;
        self.last_approve_id = id;
    }
    fn enqueueFn(ctx: *anyopaque, epoch: u64, kind: session_client.QueueKind, value: []const u8) anyerror!void {
        const self = from(ctx);
        self.enqueues += 1;
        self.last_enqueue_epoch = epoch;
        self.last_enqueue_kind = kind;
        self.record(value);
    }
    fn withdrawFn(_: *anyopaque, _: std.mem.Allocator, _: u64, _: u64) anyerror!?[]u8 {
        return null;
    }
    fn queueResumeFn(ctx: *anyopaque, _: u64) anyerror!void {
        from(ctx).resumes += 1;
    }
    fn manageFn(ctx: *anyopaque, a: std.mem.Allocator, request: session_client.Manage) anyerror!session_client.Outcome {
        const self = from(ctx);
        self.manages += 1;
        self.last_manage = std.meta.activeTag(request);
        if (self.manage_failure) |failure| return failure;
        if (request == .saved_sessions) if (self.saved_fixture) |saved| return .{ .saved_sessions = try a.dupe(session_client.SavedSession, saved) };
        if (request == .@"resume") self.record(request.@"resume");
        if (self.manage_switched) self.snapshot.control_epoch +%= 1;
        return .{ .switched = self.manage_switched, .exit = self.manage_exit };
    }
    fn detachFn(ctx: *anyopaque) void {
        from(ctx).detaches += 1;
    }

    const vtable = session_client.VTable{
        .snapshot_fn = snapshotFn,
        .submit_fn = submitFn,
        .poll_fn = pollFn,
        .buffered_fn = bufferedFn,
        .acknowledge_fn = acknowledgeFn,
        .acknowledge_range_fn = acknowledgeRangeFn,
        .cancel_fn = cancelFn,
        .cancel_clear_fn = cancelClearFn,
        .set_confirming_fn = setConfirmingFn,
        .approve_fn = approveFn,
        .enqueue_fn = enqueueFn,
        .withdraw_fn = withdrawFn,
        .queue_resume_fn = queueResumeFn,
        .manage_fn = manageFn,
        .detach_fn = detachFn,
    };

    fn current(ctx: *anyopaque) Connection.State {
        const self = from(ctx);
        return .{
            .runtime = null,
            .available = self.snapshot.available,
            .busy = self.snapshot.busy,
            .session_id = self.snapshot.session_id,
            .control_epoch = self.snapshot.control_epoch,
            .model = "fixture",
            .codex_login = self.codex,
            .subagents = self.snapshot.subagents,
            .subagents_supported = self.snapshot.subagents_supported,
            .base_url = "",
        };
    }
    fn configure(_: *anyopaque, _: []const u8) !void {
        return error.FixtureNotConfigured;
    }
};

fn remoteUi(fake: *FakeRemote, bridge: *bridge_module.Bridge, cancel: *p.Cancellation) Ui {
    var ui = Ui{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .connection = .{ .context = fake, .current_fn = FakeRemote.current, .configure_fn = FakeRemote.configure, .session_client = fake.client() },
        .bridge = bridge,
        .cancel = cancel,
        .terminal = undefined,
        .editor = .{ .allocator = std.testing.allocator },
        .job = .{ .runtime = undefined, .cancel = cancel, .prompt = "" },
        .size = .{ .columns = 80, .rows = 24 },
    };
    ui.adoptRemoteSession(fake.client());
    return ui;
}

const resume_test_sessions = [_]session_client.SavedSession{
    .{ .id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".*, .modified_ms = 1709210040000, .title = @import("../core/session_metadata.zig").Title.fromText("同一标题") },
    .{ .id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".*, .modified_ms = 1, .title = @import("../core/session_metadata.zig").Title.fromText("同一标题") },
};

fn drainBridge(ui: *Ui) !void {
    while (ui.bridge.pop()) |value| {
        var item = value;
        defer item.deinit();
        try ui.event(item);
    }
}

fn typeDraft(ui: *Ui, value: []const u8) !void {
    _ = try ui.editor.insert(value);
}

fn testAgent(id: u64, revision: u64, phase: @import("../core/subagent_status.zig").Phase, elapsed_ms: u64, detail: []const u8) @import("../core/subagent_status.zig").AgentView {
    var agent: @import("../core/subagent_status.zig").AgentView = .{ .id = id, .revision = revision, .phase = phase, .elapsed_ms = elapsed_ms };
    const n = @min(detail.len, agent.text_buf.len);
    @memcpy(agent.text_buf[0..n], detail[0..n]);
    agent.text_len = @intCast(n);
    return agent;
}

const cropped_approval_body = "CROP-FIRST\n" ++
    "CROP-FILLER\nCROP-FILLER\nCROP-FILLER\nCROP-FILLER\nCROP-FILLER\n" ++
    "CROP-FILLER\nCROP-FILLER\nCROP-FILLER\nCROP-FILLER\nCROP-FILLER\n" ++
    "CROP-FILLER\nCROP-FILLER\nCROP-FILLER\nCROP-FILLER\nCROP-FILLER\n" ++
    "CROP-FILLER\nCROP-FILLER\nCROP-FILLER\nCROP-FILLER\nCROP-FILLER\n" ++
    "CROP-FILLER\nCROP-FILLER\nCROP-FILLER\nCROP-FILLER\nCROP-FILLER\n" ++
    "CROP-FILLER\nCROP-FILLER\nCROP-FILLER\nCROP-FILLER\nCROP-FILLER\n" ++
    "CROP-LAST";

const FakeAsync = struct {
    requests: [8]?*remote_action.Owned = @splat(null),
    next: usize = 0,
    completed: ?remote_action.Completion = null,

    fn channel(self: *FakeAsync) remote_action.Channel {
        return .{ .context = self, .start_fn = start, .poll_fn = poll, .wake_fd = -1 };
    }
    fn start(raw: *anyopaque, epoch: u64, action: remote_action.Action) !u64 {
        const self: *FakeAsync = @ptrCast(@alignCast(raw));
        if (self.next == self.requests.len) return error.QueueFull;
        const ticket: u64 = @intCast(self.next + 1);
        self.requests[self.next] = try remote_action.Owned.create(std.testing.allocator, ticket, 1, epoch, action);
        self.next += 1;
        return ticket;
    }
    fn poll(raw: *anyopaque) ?remote_action.Completion {
        const self: *FakeAsync = @ptrCast(@alignCast(raw));
        const value = self.completed;
        self.completed = null;
        return value;
    }
    fn complete(self: *FakeAsync, value: remote_action.Value, failure: ?anyerror, obsolete: bool) void {
        std.debug.assert(self.completed == null);
        for (&self.requests) |*slot| if (slot.*) |request| {
            self.completed = .{ .request = request, .value = value, .failure = failure, .obsolete = obsolete };
            slot.* = null;
            return;
        };
        unreachable;
    }
    fn deinit(self: *FakeAsync) void {
        for (self.requests) |slot| if (slot) |request| request.deinit();
        if (self.completed) |*value| value.deinit();
    }
};

fn expectConfigureContextDraw(ui: *Ui, screen: *@import("../tests/regular_screen.zig").Screen, expected: ?r.ContextSnapshot, label: []const u8) !void {
    try ui.draw();
    try screen.replay(ui.frame);
    try std.testing.expectEqualDeep(expected, ui.display.context);
    try std.testing.expect(std.mem.find(u8, &screen.grid[screen.row], label) != null);
    testAcknowledgeFullFrame(ui);
}
