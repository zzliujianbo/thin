test "bold prompt preserves every color and resets before the editor at every width" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "", "模型-name" }) |model| for ([_]usize{ 1, 7, 12, 80 }) |columns| for ([_]bool{ false, true }) |busy| for ([_]?shared.ReasoningEffort{ null, .high }) |flash| {
        const motion: PromptActivity = .{ .busy = busy, .now_ms = 120, .phase = 7, .reasoning_effort = .high, .low_price_input = true, .effort_flash = flash };
        const rendered = try prompt(a, model, .{ .tokens = 25, .limit = 100 }, columns, motion);
        defer rendered.deinit(a);
        const layout = try promptLayout(a, model, .{ .tokens = 25, .limit = 100 }, columns, motion);
        defer layout.deinit(a);
        try expectPromptStyle(layout.styled, rendered.styled);
        try std.testing.expectEqualStrings(layout.plain, rendered.plain);
        var at: usize = 0;
        var glyph: usize = 0;
        var bold = false;
        while (at < rendered.styled.len) {
            if (rendered.styled[at] == '\x1b') {
                const end = std.mem.findScalarPos(u8, rendered.styled, at, 'm') orelse return error.TestUnexpectedResult;
                const parameters = rendered.styled[at + 2 .. end];
                if (std.mem.eql(u8, parameters, "0")) bold = false;
                if (std.mem.eql(u8, parameters, "1")) bold = true;
                at = end + 1;
            } else {
                try std.testing.expectEqual(glyph + 1 < rendered.plain.len, bold);
                try std.testing.expectEqual(rendered.plain[glyph], rendered.styled[at]);
                glyph += 1;
                at += 1;
            }
        }
        try std.testing.expectEqual(rendered.plain.len, glyph);
        try std.testing.expect(!bold);
    };
}
test "unselected model prompt shows no preset ID policy marker or percentage" {
    for ([_]usize{ 1, 12, 80 }) |columns| {
        const rendered = try prompt(std.testing.allocator, "", .{ .tokens = 0, .limit = 1000000 }, columns, .{ .low_price_input = true });
        defer rendered.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("> ", rendered.plain);
        try expectPromptStyle("> ", rendered.styled);
    }
}
test "unselected synchronizing prompt is not a ready marker" {
    const rendered = try prompt(std.testing.allocator, "", null, 80, .{ .busy = true });
    defer rendered.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, "> ", rendered.plain));
    try std.testing.expectEqual(@as(usize, 2), text.width(rendered.plain));
}
test "normal preview captions show names until reliable typed fields arrive" {
    const a = std.testing.allocator;
    const early = try fromToolView(a, "write_file", .{});
    defer early.deinit(a);
    try std.testing.expectEqualStrings("write_file", early.label);
    const target = try fromToolView(a, "write_file", .{ .path = .{ .text = "src/中文.zig" } });
    defer target.deinit(a);
    try std.testing.expectEqualStrings("src/中文.zig", target.label);
    try std.testing.expect(target.write_marks == null);
    const hostile = try fromToolView(a, "unknown\x1b[2J\nname", .{});
    defer hostile.deinit(a);
    try std.testing.expect(std.mem.findScalar(u8, hostile.label, '\x1b') == null);
    try std.testing.expect(std.mem.findScalar(u8, hostile.label, '\n') == null);
    const body = try commandText(a, target, .pending, " ");
    defer a.free(body);
    const line = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .pending, .label_start = commandPrefixLen(target, .pending, " ") }}, 80, null, null);
    defer a.free(line);
    try std.testing.expect(std.mem.find(u8, line, theme.reset ++ theme.muted ++ " " ++ theme.tool_name ++ " write_file " ++ theme.muted ++ "src/中文.zig") != null);
    try std.testing.expect(std.mem.find(u8, line, "⠋") == null);
    try std.testing.expect(std.mem.find(u8, line, "0ms") == null);
}
test "failed rows keep the reason on its own bounded row" {
    const a = std.testing.allocator;
    const output = @import("markdown_writer.zig");
    const captioned = try fromToolView(a, "read_file", .{ .path = .{ .text = "tests/unit/app/session_host_test.zig" } });
    defer captioned.deinit(a);
    var failed = captioned;
    failed.failure_reason = "FileNotFound: file not found";
    const body = try commandText(a, failed, .failed, " ");
    defer a.free(body);
    try std.testing.expect(std.mem.startsWith(u8, body, "✗ read_file "));
    try std.testing.expect(std.mem.indexOf(u8, body, " ✗") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "FileNotFound") == null);
    // The reason row keeps the whole width, leaves the status slot empty and
    // marks the detail as a branch of the failed row above.
    const wide = try failureReasonLine(a, failed.failure_reason.?, 200);
    defer a.free(wide);
    try std.testing.expect(std.mem.startsWith(u8, wide, theme.failure ++ "  ↳ FileNotFound: file not found"));
    try std.testing.expect(output.displayWidth(wide) <= 200);
    // A narrow reason is clipped with dots, never dropped.
    const long = "exit 2: sed: can't read a/very/long/path/that/does/not/fit/in/the/row";
    const narrow = try failureReasonLine(a, long, 40);
    defer a.free(narrow);
    try std.testing.expect(std.mem.startsWith(u8, narrow, theme.failure ++ "  ↳ exit 2: sed"));
    try std.testing.expect(std.mem.endsWith(u8, narrow, "..." ++ theme.reset));
    try std.testing.expect(output.displayWidth(narrow) <= commandColumns(40));
    // Tiny rows drop the icon first, then the indent, instead of overflowing.
    inline for ([_]usize{ 1, 2, 3, 4, 5, 6 }) |tiny_columns| {
        const tiny_line = try failureReasonLine(a, "denied", tiny_columns);
        defer a.free(tiny_line);
        try std.testing.expect(output.displayWidth(tiny_line) <= tiny_columns);
        if (tiny_columns > 4) try std.testing.expect(std.mem.indexOf(u8, tiny_line, "↳") != null) else try std.testing.expect(std.mem.indexOf(u8, tiny_line, "↳") == null);
    }
    // No reason means no second row at all.
    failed.failure_reason = null;
    const silent = try commandText(a, failed, .failed, " ");
    defer a.free(silent);
    try std.testing.expect(std.mem.startsWith(u8, silent, "✗ read_file "));
}
fn expectFailureReason(a: std.mem.Allocator, kind: shared.tools.Kind, result: @import("../core/runtime.zig").Execution, expected: []const u8) !void {
    const reason = try shared.tools.failureReason(a, kind, result);
    defer if (reason) |value| a.free(value);
    try std.testing.expectEqualStrings(expected, reason orelse "");
}
test "every failed tool owns a bounded reason and never a raw body" {
    const a = std.testing.allocator;
    try expectFailureReason(a, .write, .{ .text = "AccessDenied", .is_error = true }, "AccessDenied");
    // read 行只显示运行时给出的原始错误名，不再追加英文注释。
    try expectFailureReason(a, .read, .{ .text = "FileNotFound", .is_error = true }, "FileNotFound");
    // bash results are our own envelope: only structured failure facts surface.
    try expectFailureReason(a, .bash, .{ .text = "{\"exit_code\":7,\"stderr\":\"boom\"}", .is_error = true }, "exit 7: boom");
    try expectFailureReason(a, .bash, .{ .text = "{\"exit_code\":2,\"stderr\":\"sed: can't read missing.zig\\nmore\"}", .is_error = true }, "exit 2: sed: can't read missing.zig ... more");
    try expectFailureReason(a, .bash, .{ .text = "{\"timed_out\":true}", .is_error = true }, "timed out");
    try expectFailureReason(a, .bash, .{ .text = "{\"signal\":9}", .is_error = true }, "signal 9 (SIGKILL)");
    try expectFailureReason(a, .bash, .{ .text = "Command cleanup could not be confirmed. A child may remain alive.", .is_error = true }, "command failed");
    // stdout is only a labelled fallback when stderr has no printable line.
    try expectFailureReason(a, .bash, .{ .text = "{\"stdout\":\"secret\",\"stderr\":\"\",\"exit_code\":1}", .is_error = true }, "exit 1 (stderr empty); stdout: secret");
    try expectFailureReason(a, .bash, .{ .text = "{\"stderr\":\"has-error\",\"stdout\":\"normal-output\",\"exit_code\":1}", .is_error = true }, "exit 1: has-error");
    try expectFailureReason(a, .bash, .{ .text = "{\"exit_code\":137,\"stderr\":\"\"}", .is_error = true }, "exit 137 (stderr empty)");
    // A capture larger than the old JSON string cap still exposes the exit code.
    {
        const big = try a.alloc(u8, 1024 * 1024 + 32);
        defer a.free(big);
        @memset(big, 'x');
        const envelope = try std.fmt.allocPrint(a, "{{\"stdout\":\"{s}\",\"stderr\":\"\",\"exit_code\":1}}", .{big});
        defer a.free(envelope);
        const reason = (try shared.tools.failureReason(a, .bash, .{ .text = envelope, .is_error = true })).?;
        defer a.free(reason);
        try std.testing.expect(std.mem.startsWith(u8, reason, "exit 1 (stderr empty); stdout: xxx"));
    }
    // Other tools expose the sanitized first line only.
    try expectFailureReason(a, .other, .{ .text = "Boom: line one\nline two", .is_error = true }, "Boom: line one");
    try expectFailureReason(a, .other, .{ .text = "{\"error\":\"invalid log offset\",\"id\":\"job-1\"}", .is_error = true }, "invalid log offset");
    try expectFailureReason(a, .other, .{ .text = "  \n\t", .is_error = true }, "");
    try expectFailureReason(a, .write, .{ .text = "AccessDenied", .is_error = true, .canceled = true }, "");
    try expectFailureReason(a, .write, .{ .text = "AccessDenied" }, "");
}
test "bash rows show the tool name then the command and keep the slot" {
    const a = std.testing.allocator;
    const early = try fromToolView(a, "bash", .{});
    defer early.deinit(a);
    const empty_body = try commandText(a, early, .pending, " ");
    defer a.free(empty_body);
    try std.testing.expectEqualStrings("  bash", empty_body);
    const ready = try fromToolView(a, "bash", .{ .command = .{ .text = "printf owned" } });
    defer ready.deinit(a);
    const canonical = try caption(a, "bash", "{\"command\":\"printf owned\"}");
    defer canonical.deinit(a);
    try std.testing.expectEqualStrings(ready.label, canonical.label);
    inline for (.{ Outcome.pending, Outcome.success, Outcome.failed, Outcome.canceled }) |outcome| {
        const body = try commandText(a, ready, outcome, " ");
        defer a.free(body);
        const expected = switch (outcome) {
            .pending => "  bash printf owned",
            .success => "✓ bash printf owned",
            .failed => "✗ bash printf owned",
            .canceled => "- bash printf owned",
        };
        try std.testing.expectEqualStrings(expected, body);
        try std.testing.expect(std.mem.find(u8, body, "> bash ") == null);
    }
    const done = try completed(a, canonical, null);
    defer done.deinit(a);
    try std.testing.expectEqualStrings("printf owned", done.label);
    // The executable named bash is command text, never confused with the name.
    const actual_bash = try caption(a, "bash", "{\"command\":\"bash run.sh\"}");
    defer actual_bash.deinit(a);
    const actual_body = try commandText(a, actual_bash, .pending, " ");
    defer a.free(actual_body);
    try std.testing.expectEqualStrings("  bash bash run.sh", actual_body);
}
test "command captions are bounded single line UTF8 with literal three dots" {
    const a = std.testing.allocator;
    const cmd = try caption(a, "bash", "{\"command\":\"date\\nwhoami\\tmore\"}");
    defer cmd.deinit(a);
    try std.testing.expectEqualStrings("date whoami more", cmd.label);
    const long = try singleLine(a, "abcdefghi", 7);
    defer a.free(long);
    try std.testing.expectEqualStrings("abcd...", long);
    const hostile = try singleLine(a, "你你你\x1b[2J\ntrailing", 7);
    defer a.free(hostile);
    try std.testing.expect(std.unicode.utf8ValidateSlice(hostile));
    try std.testing.expect(text.width(hostile) <= 7);
    try std.testing.expect(std.mem.findScalar(u8, hostile, '\x1b') == null);
    try std.testing.expect(std.mem.findScalar(u8, hostile, '\n') == null);
    try std.testing.expect(std.mem.endsWith(u8, hostile, "..."));
    const incomplete = try caption(a, "bash", "{\"command\":\"partial");
    defer incomplete.deinit(a);
    try std.testing.expectEqualStrings("(command unavailable)", incomplete.label);
}
test "percent prompt has default input colors and real spinner not loading text" {
    const a = std.testing.allocator;
    const idle = try prompt(a, "deepseek-flash", null, 79, .{});
    defer idle.deinit(a);
    try std.testing.expectEqualStrings("(deepseek-flash) ?%> ", idle.plain);
    try expectPromptStyle(idle.plain, idle.styled);
    const active = try prompt(a, "deepseek-flash", null, 79, .{ .busy = true, .streaming = true, .now_ms = 80, .phase = 2 });
    defer active.deinit(a);
    try std.testing.expectEqualStrings("(deepseek-flash) ?%⠙ ", active.plain);
    try expectPromptSuffix(active.styled, theme.reset ++ theme.command_pulse[1] ++ "⠙" ++ theme.reset ++ " ");
    try std.testing.expect(std.mem.find(u8, active.styled, "loading") == null);
    const narrow = try prompt(a, "long model name", null, 7, .{});
    defer narrow.deinit(a);
    try std.testing.expectEqualStrings("> ", narrow.plain);
    const hostile = try prompt(a, "你\x1b[2J\nname", null, 30, .{ .busy = true });
    defer hostile.deinit(a);
    try std.testing.expect(text.width(hostile.plain) < 30);
    try std.testing.expect(std.mem.find(u8, hostile.styled, "\x1b[2J") == null);
}
test "file captions expose safe paths and measured counts with unknown not guessed" {
    const a = std.testing.allocator;
    const read = try caption(a, "read_file", "{\"path\":\"src/main.zig\",\"offset\":100}");
    defer read.deinit(a);
    const done = try completed(a, read, .{ .read = 12, .partial = true });
    defer done.deinit(a);
    try std.testing.expectEqualStrings("src/main.zig  12 lines [partial]", done.label);
    const write = try caption(a, "write_file", "{\"path\":\"a.zig\",\"content\":\"secret-body-not-a-caption\"}");
    defer write.deinit(a);
    const changed = try completed(a, write, .{ .changes = .{ .modified = 3, .added = 5, .removed = 2 } });
    defer changed.deinit(a);
    try std.testing.expectEqualStrings("a.zig  ~3 +5 -2 lines", changed.label);
    const unknown = try completed(a, write, null);
    defer unknown.deinit(a);
    try std.testing.expectEqualStrings("a.zig  changes ?", unknown.label);
    const edit = try caption(a, "edit_file", "{\"path\":\"a.zig\",\"edits\":[{\"old_text\":\"secret-before\",\"new_text\":\"secret-after\"}]}");
    defer edit.deinit(a);
    try std.testing.expectEqual(activity.Tool.edit, edit.kind);
    try std.testing.expectEqualStrings("a.zig", edit.label);
    const edit_done = try completed(a, edit, .{ .changes = .{ .modified = 1, .added = 2, .removed = 3 } });
    defer edit_done.deinit(a);
    try std.testing.expectEqual(activity.Tool.edit, edit_done.kind);
    try std.testing.expectEqualStrings("a.zig  ~1 +2 -3 lines", edit_done.label);
    const edit_text = try commandText(a, edit_done, .success, " ");
    defer a.free(edit_text);
    try std.testing.expect(std.mem.startsWith(u8, edit_text, "✓ edit_file "));
    try std.testing.expect(std.mem.indexOf(u8, edit_text, "secret-") == null);
    const bad = try caption(a, "write_file", "{\"path\":\"unfinished");
    defer bad.deinit(a);
    try std.testing.expectEqualStrings("(file unavailable)", bad.label);
}
test "provisional write counts are explicit typed preview and generation stays muted" {
    const a = std.testing.allocator;
    const value: Caption = .{ .kind = .write, .label = "preview.zig" };
    const known = try provisionalWrite(a, value, .{ .added = 12, .deleted = 3 });
    defer known.deinit(a);
    try std.testing.expectEqualStrings("preview.zig  +12 -3 preview", known.label);
    const body = try commandText(a, known, .pending, " ");
    defer a.free(body);
    const span: CommandSpan = .{ .start = 0, .end = body.len, .outcome = .pending, .write_marks = known.write_marks.?.shifted(commandPrefixLen(known, .pending, " ")), .generating = true, .label_start = commandPrefixLen(known, .pending, " ") };
    const first = try commandLine(a, body, &.{span}, 80, null, 0);
    defer a.free(first);
    const second = try commandLine(a, body, &.{span}, 80, null, 900);
    defer a.free(second);
    // Generation is not execution: the icon stays in place, neutral and static,
    // and no running brightness may claim the call has started.
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.startsWith(u8, first, theme.reset ++ theme.muted ++ " " ++ theme.tool_name ++ " write_file " ++ theme.muted ++ "preview.zig"));
    for (theme.flow_band) |tone| try std.testing.expect(std.mem.indexOf(u8, first, tone) == null);
    try std.testing.expect(std.mem.indexOf(u8, first, theme.diff_added ++ "+12") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, theme.diff_removed ++ "-3") != null);
    const unknown = try provisionalWrite(a, value, .{});
    defer unknown.deinit(a);
    try std.testing.expectEqualStrings("preview.zig  +? -? preview", unknown.label);
}
test "write count colors use numeric metadata not patterns in a hostile path" {
    const a = std.testing.allocator;
    const value: Caption = .{ .kind = .write, .label = "path +99 -88 中文" };
    const done = try completed(a, value, .{ .changes = .{ .modified = 4, .added = 12, .removed = 34 } });
    defer done.deinit(a);
    const body = try commandText(a, done, .success, " ");
    defer a.free(body);
    const span: CommandSpan = .{ .start = 0, .end = body.len, .outcome = .success, .write_marks = done.write_marks.?.shifted(commandPrefixLen(done, .success, " ")), .label_start = commandPrefixLen(done, .success, " ") };
    const line = try commandLine(a, body, &.{span}, 200, null, null);
    defer a.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, theme.reset ++ theme.success ++ "✓" ++ theme.tool_name ++ " write_file " ++ theme.muted ++ "path +99 -88 中文  ~4 "));
    try std.testing.expect(std.mem.indexOf(u8, line, theme.diff_added ++ "+12" ++ theme.muted) != null);
    try std.testing.expect(std.mem.indexOf(u8, line, theme.diff_removed ++ "-34" ++ theme.muted) != null);
    for ([_]usize{ 1, 4, 20, 45, 55 }) |columns| {
        const clipped = try commandLine(a, body, &.{span}, columns, null, null);
        defer a.free(clipped);
        try std.testing.expect(@import("markdown_writer.zig").displayWidth(clipped) <= commandColumns(columns));
        try std.testing.expect(std.unicode.utf8ValidateSlice(clipped));
        try std.testing.expect(std.mem.indexOf(u8, clipped, theme.diff_added ++ "...") == null);
        try std.testing.expect(std.mem.indexOf(u8, clipped, theme.diff_removed ++ "...") == null);
    }
    const unknown = try completed(a, value, null);
    defer unknown.deinit(a);
    try std.testing.expect(unknown.write_marks == null);
}
test "context prompt is retained occupancy not cache billing and remains bounded at small widths" {
    const a = std.testing.allocator;
    const value = try prompt(a, "fixture", .{ .tokens = 16384, .limit = 32768 }, 79, .{});
    defer value.deinit(a);
    try std.testing.expectEqualStrings("(fixture) 50.0%> ", value.plain);
    try expectPromptStyle("(" ++ theme.reset ++ "fixture" ++ theme.reset ++ ") " ++ theme.failure ++ "50.0%" ++ theme.reset ++ "> ", value.styled);
    for ([_]usize{ 1, 7, 24, 40, 79, 119 }) |width| {
        const small = try prompt(a, "long-model-name", .{ .tokens = std.math.maxInt(u64), .limit = 1 }, width, .{ .busy = true, .streaming = true, .now_ms = 80, .phase = 1 });
        defer small.deinit(a);
        try std.testing.expect(text.width(small.plain) <= @max(width, 2));
        try std.testing.expect(std.mem.find(u8, small.styled, "loading") == null);
    }
    const zero = try prompt(a, "fixture", .{ .tokens = 9000, .limit = 0 }, 79, .{});
    defer zero.deinit(a);
    try std.testing.expect(std.mem.find(u8, zero.plain, "?%") != null);
}
test "context percent thresholds follow displayed rounding without animation or overflow" {
    const a = std.testing.allocator;
    const cases = [_]struct { snapshot: ?shared.ContextSnapshot, label: []const u8, color: []const u8 }{
        .{ .snapshot = null, .label = "?%", .color = theme.reset },
        .{ .snapshot = .{ .tokens = 10, .limit = 100, .known = false }, .label = "?%", .color = theme.reset },
        .{ .snapshot = .{ .tokens = 10, .limit = 0 }, .label = "?%", .color = theme.reset },
        .{ .snapshot = .{ .tokens = 0, .limit = 100 }, .label = "0.0%", .color = theme.success },
        .{ .snapshot = .{ .tokens = 24949, .limit = 100000 }, .label = "24.9%", .color = theme.success },
        .{ .snapshot = .{ .tokens = 24950, .limit = 100000 }, .label = "25.0%", .color = "\x1b[38;5;220m" },
        .{ .snapshot = .{ .tokens = 25, .limit = 100 }, .label = "25.0%", .color = "\x1b[38;5;220m" },
        .{ .snapshot = .{ .tokens = 49949, .limit = 100000 }, .label = "49.9%", .color = "\x1b[38;5;220m" },
        .{ .snapshot = .{ .tokens = 49950, .limit = 100000 }, .label = "50.0%", .color = theme.failure },
        .{ .snapshot = .{ .tokens = 50, .limit = 100 }, .label = "50.0%", .color = theme.failure },
        .{ .snapshot = .{ .tokens = std.math.maxInt(u64), .limit = std.math.maxInt(u64) }, .label = "100.0%", .color = theme.failure },
        .{ .snapshot = .{ .tokens = std.math.maxInt(u64), .limit = 1 }, .label = ">100%", .color = theme.failure },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |busy| {
            for ([_]usize{ 0, 11 }) |phase| {
                const value = try prompt(a, "fixture", case.snapshot, 79, .{ .busy = busy, .now_ms = 80, .phase = phase, .rate_band = .fast, .reasoning_effort = .high });
                defer value.deinit(a);
                const suffix = try std.fmt.allocPrint(a, ") {s}{s}{s}{s}{s}{s} ", .{ case.color, case.label, theme.reset, if (busy) theme.command_pulse[1] else "", if (busy) activity.spinner(80) else ">", if (busy) theme.reset else "" });
                defer a.free(suffix);
                try expectPromptSuffix(value.styled, suffix);
                try std.testing.expectEqual(text.width(value.plain), @import("markdown_writer.zig").displayWidth(value.styled));
            }
        }
    }
}
test "low price marker shares the full static context color and optout removes it" {
    const a = std.testing.allocator;
    const cases = [_]struct { snapshot: ?shared.ContextSnapshot, label: []const u8, color: []const u8 }{
        .{ .snapshot = null, .label = "?%", .color = theme.reset },
        .{ .snapshot = .{ .tokens = 10, .limit = 100, .known = false }, .label = "?%", .color = theme.reset },
        .{ .snapshot = .{ .tokens = 0, .limit = 100 }, .label = "0.0%", .color = theme.success },
        .{ .snapshot = .{ .tokens = 24949, .limit = 100000 }, .label = "24.9%", .color = theme.success },
        .{ .snapshot = .{ .tokens = 24950, .limit = 100000 }, .label = "25.0%", .color = "\x1b[38;5;220m" },
        .{ .snapshot = .{ .tokens = 49949, .limit = 100000 }, .label = "49.9%", .color = "\x1b[38;5;220m" },
        .{ .snapshot = .{ .tokens = 49950, .limit = 100000 }, .label = "50.0%", .color = theme.failure },
        .{ .snapshot = .{ .tokens = std.math.maxInt(u64), .limit = 1 }, .label = ">100%", .color = theme.failure },
    };
    for (cases) |case| for ([_]bool{ false, true }) |enabled| for ([_]bool{ false, true }) |busy| for ([_]usize{ 0, 11 }) |phase| {
        const value = try prompt(a, "fixture", case.snapshot, 79, .{ .busy = busy, .now_ms = 80, .phase = phase, .rate_band = .fast, .reasoning_effort = .high, .low_price_input = enabled });
        defer value.deinit(a);
        const suffix = try std.fmt.allocPrint(a, ") {s}{s}{s}{s}{s}{s}{s} ", .{ case.color, if (enabled) "L" else "", case.label, theme.reset, if (busy) theme.command_pulse[1] else "", if (busy) activity.spinner(80) else ">", if (busy) theme.reset else "" });
        defer a.free(suffix);
        try expectPromptSuffix(value.styled, suffix);
        const label = try std.mem.concat(a, u8, &.{ "L", case.label });
        defer a.free(label);
        try std.testing.expectEqual(enabled, std.mem.find(u8, value.plain, label) != null);
        try std.testing.expect(std.mem.find(u8, value.plain, "L ") == null);
        try std.testing.expectEqual(text.width(value.plain), @import("markdown_writer.zig").displayWidth(value.styled));
    };
    for (0..80) |columns| {
        const value = try prompt(a, "a very long model name", .{ .tokens = 10, .limit = 100 }, columns, .{ .low_price_input = true, .busy = true, .streaming = true });
        defer value.deinit(a);
        try std.testing.expect(text.width(value.plain) <= @max(columns, 2));
        try std.testing.expectEqual(text.width(value.plain), @import("markdown_writer.zig").displayWidth(value.styled));
        if (std.mem.findScalar(u8, value.plain, 'L') != null) try std.testing.expect(std.mem.find(u8, value.plain, "L10.0%") != null);
    }
}
test "model closes before adjacent policy and percentage while punctuation stays default" {
    const a = std.testing.allocator;
    const value = try prompt(a, "deepseek-flash", .{ .tokens = 16, .limit = 1000 }, 79, .{ .reasoning_effort = .high, .low_price_input = true });
    defer value.deinit(a);
    try std.testing.expectEqualStrings("(deepseek-flash) L1.6%> ", value.plain);
    const model_color = comptime theme.effortColor(.high);
    try expectPromptStyle("(" ++ model_color ++ "deepseek-flash" ++ theme.reset ++ ") " ++ theme.success ++ "L1.6%" ++ theme.reset ++ "> ", value.styled);
    const optout = try prompt(a, "deepseek-flash", .{ .tokens = 16, .limit = 1000 }, 79, .{ .low_price_input = false });
    defer optout.deinit(a);
    try std.testing.expectEqualStrings("(deepseek-flash) 1.6%> ", optout.plain);
    const compact = try prompt(a, "x", .{ .tokens = 16, .limit = 1000 }, 12, .{ .low_price_input = true });
    defer compact.deinit(a);
    try std.testing.expectEqualStrings("L1.6%> ", compact.plain);
    try expectPromptStyle(theme.success ++ "L1.6%" ++ theme.reset ++ "> ", compact.styled);
}
test "low price marker stays context colored during effort flashes" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |busy| {
        const value = try prompt(a, "fixture", .{ .tokens = 50, .limit = 100 }, 79, .{ .busy = busy, .reasoning_effort = .medium, .effort_flash = .medium, .phase = 7, .low_price_input = true });
        defer value.deinit(a);
        try std.testing.expect(std.mem.find(u8, value.plain, "Lmedium") != null);
        try std.testing.expect(std.mem.find(u8, value.styled, theme.failure ++ "L" ++ theme.reset) != null);
        try std.testing.expect(std.mem.find(u8, value.plain, "L ") == null);
        try std.testing.expectEqual(text.width(value.plain), @import("markdown_writer.zig").displayWidth(value.styled));
    }
}
test "effort confirmation replaces only the context slot and medium stays default color" {
    const a = std.testing.allocator;
    const context: shared.ContextSnapshot = .{ .tokens = 25, .limit = 100 };
    const flash = try prompt(a, "fixture", context, 79, .{ .reasoning_effort = .medium, .effort_flash = .medium });
    defer flash.deinit(a);
    try std.testing.expectEqualStrings("(fixture) medium> ", flash.plain);
    try expectPromptStyle(flash.plain, flash.styled);
    const restored = try prompt(a, "fixture", context, 79, .{ .reasoning_effort = .medium });
    defer restored.deinit(a);
    try std.testing.expectEqualStrings("(fixture) 25.0%> ", restored.plain);
    const busy = try prompt(a, "fixture", context, 79, .{ .busy = true, .streaming = true, .reasoning_effort = .high, .effort_flash = .high });
    defer busy.deinit(a);
    try std.testing.expect(std.mem.startsWith(u8, busy.plain, "(fixture) high"));
    for (0..80) |columns| {
        const narrow = try prompt(a, "very long model name", context, columns, .{ .reasoning_effort = .minimal, .effort_flash = .minimal });
        defer narrow.deinit(a);
        try std.testing.expect(text.width(narrow.plain) <= @max(columns, 2));
    }
}
test "model keeps effort and TPS waves while context percent has static occupancy color" {
    const a = std.testing.allocator;
    const efforts = [_]shared.ReasoningEffort{ .unspecified, .unknown, .off, .minimal, .low, .medium, .high, .xhigh };
    for ([_]shared.activity.RateBand{ .slow, .standard, .fast, .unknown }) |band| {
        const palette = theme.modelPalette(band);
        for ([_]usize{ 0, 2, 11, std.math.maxInt(usize) }) |phase| {
            for ([_]u64{ 0, 80, 120 }) |now| {
                // Only the model flows; the complete percentage stays green
                // regardless of phase, rate, spinner time or configured effort.
                var expected: std.Io.Writer.Allocating = .init(a);
                defer expected.deinit();
                try expected.writer.writeAll("(");
                for ("model", 0..) |byte, ordinal| {
                    try expected.writer.print("{s}{c}", .{ palette[(phase % palette.len + ordinal) % palette.len], byte });
                }
                try expected.writer.print("{s}) {s}2.3%{s}{s}{s}{s} ", .{ theme.reset, theme.success, theme.reset, theme.command_pulse[(now / 80) % theme.command_pulse.len], activity.spinner(now), theme.reset });
                for (efforts) |effort| {
                    const value = try prompt(a, "model", .{ .tokens = 22807, .limit = 1000000 }, 79, .{ .busy = true, .streaming = true, .now_ms = now, .phase = phase, .rate_band = band, .reasoning_effort = effort });
                    defer value.deinit(a);
                    try expectPromptStyle(expected.written(), value.styled);
                    const plain = try std.fmt.allocPrint(a, "(model) 2.3%{s} ", .{activity.spinner(now)});
                    defer a.free(plain);
                    try std.testing.expectEqualStrings(plain, value.plain);
                    try std.testing.expect(std.mem.find(u8, value.plain, "ctx") == null and std.mem.find(u8, value.plain, "/") == null);
                }
            }
        }
    }
    for (efforts) |effort| {
        const color = theme.effortColor(effort);
        const idle = try prompt(a, "model", .{ .tokens = 1, .limit = 1000 }, 79, .{ .reasoning_effort = effort });
        defer idle.deinit(a);
        const expected = try std.fmt.allocPrint(a, "({s}model{s}) {s}0.1%{s}> ", .{ color, theme.reset, theme.success, theme.reset });
        defer a.free(expected);
        try expectPromptStyle(expected, idle.styled);
        try std.testing.expectEqualStrings("(model) 0.1%> ", idle.plain);
        const percent = try prompt(a, "", null, 79, .{ .reasoning_effort = effort });
        defer percent.deinit(a);
        const percent_expected = try a.dupe(u8, percent.plain);
        defer a.free(percent_expected);
        try std.testing.expectEqualStrings("> ", percent.plain);
        try expectPromptStyle(percent_expected, percent.styled);
        for (0..12) |columns| {
            for ([_]bool{ false, true }) |busy| {
                const narrow = try prompt(a, "model", null, columns, .{ .busy = busy, .now_ms = 80, .reasoning_effort = effort });
                defer narrow.deinit(a);
                try std.testing.expectEqualStrings(if (busy) "⠙ " else "> ", narrow.plain);
                if (busy) {
                    try expectPromptStyle(theme.command_pulse[1] ++ "⠙" ++ theme.reset ++ " ", narrow.styled);
                } else try expectPromptStyle(narrow.plain, narrow.styled);
            }
        }
    }
}
test "running tool status pulses with the composer while the band flows separately" {
    try text.initLocale();
    const a = std.testing.allocator;
    const output = @import("markdown_writer.zig");
    const value: Caption = .{ .kind = .bash, .label = "target" };
    for ([_]u64{ 0, 79, 80, 119, 120, 239, 960, std.math.maxInt(u64) }) |now| {
        const color = theme.command_pulse[(now / 80) % theme.command_pulse.len];
        const icon = activity.spinner(now);
        const ending = try std.fmt.allocPrint(a, "{s}{s}{s} ", .{ color, icon, theme.reset });
        defer a.free(ending);
        const body = try commandText(a, value, .pending, icon);
        defer a.free(body);
        const span = CommandSpan{ .start = 0, .end = body.len, .outcome = .pending, .label_start = commandPrefixLen(value, .pending, icon) };
        const tool = try commandLine(a, body, &.{span}, 80, null, now);
        defer a.free(tool);
        // The status slot is the exact composer phase and palette; the flow
        // starts only after the separately colored tool name.
        const tool_prefix = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ theme.reset, color, icon, theme.tool_name, " bash " });
        defer a.free(tool_prefix);
        try std.testing.expect(std.mem.startsWith(u8, tool, tool_prefix));
        try std.testing.expectEqual(text.width(body), output.displayWidth(tool));
        for ([_]usize{ 0, 7, 12, 15, 80 }) |columns| for ([_]shared.activity.RateBand{ .slow, .fast, .unknown }) |band| {
            const rendered = try prompt(a, "model", .{ .tokens = 10, .limit = 100 }, columns, .{ .busy = true, .streaming = true, .now_ms = now, .phase = 7, .rate_band = band, .reasoning_effort = .high });
            defer rendered.deinit(a);
            try expectPromptSuffix(rendered.styled, ending);
            try std.testing.expectEqual(text.width(rendered.plain), output.displayWidth(rendered.styled));
            try std.testing.expect(text.width(rendered.plain) <= @max(columns, 2));
        };
    }
}
test "all four tool rows flow without moving glyphs, columns or widths" {
    try text.initLocale();
    const a = std.testing.allocator;
    const output = @import("markdown_writer.zig");
    const spinner = "⠋";
    for ([_]activity.Tool{ .bash, .read, .write, .memory }) |kind| {
        const value: Caption = .{ .kind = kind, .label = "operation target" };
        const name = activity.toolName(kind);
        const active_body = try commandText(a, value, .pending, spinner);
        defer a.free(active_body);
        const settled_body = try commandText(a, value, .success, " ");
        defer a.free(settled_body);
        const active_span = CommandSpan{ .start = 0, .end = active_body.len, .outcome = .pending, .label_start = commandPrefixLen(value, .pending, spinner) };
        const start = try commandLine(a, active_body, &.{active_span}, 100, null, 0);
        defer a.free(start);
        const later = try commandLine(a, active_body, &.{active_span}, 100, null, 80);
        defer a.free(later);
        // The band moved, yet every frame keeps the same glyphs and columns.
        try std.testing.expect(!std.mem.eql(u8, start, later));
        // The status slot keeps the composer's pulse and the tool name keeps its
        // own color; neither is repainted by the command band.
        const head_prefix = try std.fmt.allocPrint(a, "{s}{s}{s}{s} {s} ", .{ theme.reset, theme.command_pulse[0], spinner, theme.tool_name, name });
        defer a.free(head_prefix);
        try std.testing.expect(std.mem.startsWith(u8, start, head_prefix));
        try std.testing.expectEqual(text.width(active_body), output.displayWidth(start));
        try std.testing.expectEqual(output.displayWidth(start), output.displayWidth(later));
        // The settled row keeps the same one-column slot with its outcome glyph.
        try std.testing.expectEqual(text.width(settled_body), text.width(active_body));
        // The band bounces over the command body: the last command column is
        // fully lit at the turn. A full flow+pulse period reproduces the first
        // frame, including the synchronized status color.
        const width = output.displayWidth("operation target");
        const tail = try commandLine(a, active_body, &.{active_span}, 100, null, 40 * (width - 1));
        defer a.free(tail);
        const tail_prefix = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ theme.flow_band[0], "operation target"[15..], theme.reset });
        defer a.free(tail_prefix);
        try std.testing.expect(std.mem.endsWith(u8, tail, tail_prefix));
        // LCM(flow 2*(width-1)*40ms, pulse 8*160ms) reproduces the first frame.
        const again = try commandLine(a, active_body, &.{active_span}, 100, null, 40 * (2 * (width - 1)) * 16);
        defer a.free(again);
        try std.testing.expectEqualStrings(start, again);
        // A settled row never flows, whatever clock the caller holds.
        const done_span = CommandSpan{ .start = 0, .end = settled_body.len, .outcome = .success, .label_start = commandPrefixLen(value, .success, " ") };
        const done = try commandLine(a, settled_body, &.{done_span}, 100, null, 120);
        defer a.free(done);
        const expected = try std.fmt.allocPrint(a, "{s}{s}{s}{s} {s} {s}{s}{s}", .{ theme.reset, theme.success, statusGlyph(.success), theme.tool_name, name, theme.muted, "operation target", theme.reset });
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, done);
        for (theme.flow_band) |tone| try std.testing.expect(std.mem.indexOf(u8, done, tone) == null);
    }
    try std.testing.expectEqualStrings("read_file", activity.toolName(.read));
    try std.testing.expectEqualStrings("write_file", activity.toolName(.write));
    try std.testing.expectEqualStrings("memory", activity.toolName(.memory));
}
test "tool details survive old cutoffs and rows clip at full width with complete clusters and dots" {
    try text.initLocale();
    const a = std.testing.allocator;
    const output = @import("markdown_writer.zig");
    for ([_][]const u8{ "bash", "read_file", "write_file", "memory" }) |name| {
        const long_detail: [260]u8 = @splat('a');
        const args = if (std.mem.eql(u8, name, "bash")) try std.fmt.allocPrint(a, "{{\"command\":\"{s}\"}}", .{long_detail[0..]}) else if (std.mem.eql(u8, name, "memory")) try std.fmt.allocPrint(a, "{{\"action\":\"read\",\"topic\":\"{s}\"}}", .{long_detail[0..]}) else try std.fmt.allocPrint(a, "{{\"path\":\"{s}\"}}", .{long_detail[0..]});
        defer a.free(args);
        const value = try caption(a, name, args);
        defer value.deinit(a);
        try std.testing.expect(value.label.len >= 260);
        const body = try commandText(a, value, .pending, " ");
        defer a.free(body);
        for ([_]usize{ 0, 1, 4, 10, 80, 200, 512 }) |columns| {
            const line = try commandLine(a, body, &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .pending }}, columns, null, 80);
            defer a.free(line);
            try std.testing.expect(output.displayWidth(line) <= commandColumns(columns));
            try std.testing.expect(std.unicode.utf8ValidateSlice(line));
            if (columns >= 10 and columns <= 200) try std.testing.expect(std.mem.endsWith(u8, line, "..." ++ theme.reset));
        }
    }
    const body = "r 中文é repeated-path 中文é repeated-path 中文é repeated-path";
    const line = try commandLine(a, body, &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .pending }}, 80, null, 120);
    defer a.free(line);
    try std.testing.expect(output.displayWidth(line) <= 80);
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    try std.testing.expectEqual(@as(usize, 100), commandColumns(100));
    try std.testing.expectEqual(@as(usize, 79), commandColumns(79));
    for (0..128) |columns| try std.testing.expectEqual(columns, commandColumns(columns));
    try std.testing.expect(commandColumns(std.math.maxInt(usize)) <= std.math.maxInt(usize));
    const memory = try caption(a, "memory", "{\"action\":\"write\",\"topic\":\"core\",\"content\":\"hidden-body\"}");
    defer memory.deinit(a);
    try std.testing.expectEqualStrings("write core.md", memory.label);
    const missing = try caption(a, "memory", "{\"action\":\"invented\"}");
    defer missing.deinit(a);
    try std.testing.expectEqualStrings("(operation unavailable)", missing.label);
}
test "command duration stays last and inside the row width for every outcome" {
    try text.initLocale();
    const a = std.testing.allocator;
    const output = @import("markdown_writer.zig");
    const cases = [_]struct { ms: u64, suffix: []const u8 }{
        .{ .ms = 7, .suffix = "7ms" },
        .{ .ms = 1234, .suffix = "1.23s" },
        .{ .ms = 62000, .suffix = "1m02s" },
        .{ .ms = std.math.maxInt(u64), .suffix = "307445734561825m51s" },
    };
    for ([_]Outcome{ .pending, .success, .failed, .canceled }) |outcome| {
        const body = try commandText(a, .{ .kind = .bash, .label = "echo 中文é very-long-command 中文é very-long-command 中文é tail" }, outcome, " ");
        defer a.free(body);
        for (cases) |case| {
            const ending = try std.fmt.allocPrint(a, "  {s}{s}", .{ case.suffix, theme.reset });
            defer a.free(ending);
            for ([_]usize{ 0, 1, 7, 12, 16, 40, 79, 200 }) |columns| {
                const line = try commandLine(a, body, &.{CommandSpan{ .start = 0, .end = body.len, .outcome = outcome }}, columns, case.ms, 120);
                defer a.free(line);
                try std.testing.expect(output.displayWidth(line) <= commandColumns(columns));
                try std.testing.expect(std.unicode.utf8ValidateSlice(line));
                if (commandColumns(columns) >= case.suffix.len + 6) try std.testing.expect(std.mem.endsWith(u8, line, ending));
            }
        }
    }
}
test "only the executing row flows while completed spans stay static and clipped safely" {
    const a = std.testing.allocator;
    const body = "> sleep 1";
    const spans = &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .pending }};
    const first = try commandLine(a, body, spans, 79, null, 0);
    defer a.free(first);
    const second = try commandLine(a, body, spans, 79, null, 180);
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    // The status slot pulses with the composer palette; the band starts after it.
    try std.testing.expect(std.mem.startsWith(u8, first, theme.reset ++ theme.command_pulse[0] ++ ">"));
    try std.testing.expect(std.mem.find(u8, first, theme.flow_band[0]) != null);
    // A clip that eats the icon cannot fabricate one: no prefix, no flow.
    const narrow = try commandLine(a, "r long-path", &.{CommandSpan{ .start = 0, .end = "r long-path".len, .outcome = .pending }}, 3, null, 1);
    defer a.free(narrow);
    try std.testing.expect(std.unicode.utf8ValidateSlice(narrow));
    try std.testing.expectEqualStrings(theme.muted ++ "..." ++ theme.reset, narrow);
    for ([_]Outcome{ .success, .failed, .canceled }) |outcome| {
        const complete = &.{CommandSpan{ .start = 0, .end = body.len, .outcome = outcome }};
        const one = try commandLine(a, body, complete, 79, null, 0);
        defer a.free(one);
        const two = try commandLine(a, body, complete, 79, null, 180);
        defer a.free(two);
        try std.testing.expectEqualStrings(one, two);
    }
}
test "executing rows keep every column after the status slot while the band and spinner move" {
    try text.initLocale();
    const a = std.testing.allocator;
    const times = [_]u64{ 0, 40, 80, 120, 160, 200, 240, 280, std.math.maxInt(u64) };
    const spinner = "⠋";
    for ([_]activity.Tool{ .bash, .read, .write, .memory, .background, .other }) |kind| {
        const value: Caption = .{ .kind = kind, .label = "operation 中文 target" };
        const name = activity.toolName(kind);
        const active_body = try commandText(a, value, .pending, spinner);
        defer a.free(active_body);
        const settled_body = try commandText(a, value, .success, " ");
        defer a.free(settled_body);
        const held_body = try commandText(a, value, .pending, " ");
        defer a.free(held_body);
        const active_span = CommandSpan{ .start = 0, .end = active_body.len, .outcome = .pending, .label_start = commandPrefixLen(value, .pending, spinner) };
        const done_span = CommandSpan{ .start = 0, .end = settled_body.len, .outcome = .success, .label_start = commandPrefixLen(value, .success, " ") };
        const done = try commandLine(a, settled_body, &.{done_span}, 80, 250, 900);
        defer a.free(done);
        const done_visible = try visibleRow(a, done);
        defer a.free(done_visible);
        const done_suffix = done_visible[text.nextCluster(done_visible, 0, 0).end + 1 ..];
        var lit: [theme.flow_band.len]bool = @splat(false);
        for (times) |now| {
            const line = try commandLine(a, active_body, &.{active_span}, 80, 250, now);
            defer a.free(line);
            const visible = try visibleRow(a, line);
            defer a.free(visible);
            // Only the one-column status slot changes glyph; the tool name,
            // command and timer keep their exact columns on every frame.
            try std.testing.expectEqualStrings(done_suffix, visible[text.nextCluster(visible, 0, 0).end + 1 ..]);
            try std.testing.expectEqual(text.styledWidth(done), text.styledWidth(line));
            for (theme.flow_band, 0..) |tone, index| {
                if (std.mem.indexOf(u8, line, tone) != null) lit[index] = true;
            }
        }
        // The band sweeps with several distinct levels over its run.
        var shades: usize = 0;
        for (lit) |seen| shades += @intFromBool(seen);
        try std.testing.expect(shades >= 4);
        // Generation is not execution: the slot stays blank, the name keeps its
        // own color, and no running brightness may claim the call has started.
        for ([_]u64{ 0, 180, 900, std.math.maxInt(u64) }) |now| {
            const held_span = CommandSpan{ .start = 0, .end = held_body.len, .outcome = .pending, .generating = true, .label_start = commandPrefixLen(value, .pending, " ") };
            const generating = try commandLine(a, held_body, &.{held_span}, 80, null, now);
            defer a.free(generating);
            const expected = try std.fmt.allocPrint(a, "{s}{s} {s} {s} {s}{s}{s}", .{ theme.reset, theme.muted, theme.tool_name, name, theme.muted, "operation 中文 target", theme.reset });
            defer a.free(expected);
            try std.testing.expectEqualStrings(expected, generating);
            for (theme.flow_band) |tone| try std.testing.expect(std.mem.indexOf(u8, generating, tone) == null);
        }
    }
}
test "long byte capped paths use complete clusters and only ascii truncation dots" {
    try text.initLocale();
    const a = std.testing.allocator;
    const suffix: [30]u8 = @splat('b');
    for ([_]usize{ 497, 510, 511 }) |count| {
        const start = try a.alloc(u8, count);
        defer a.free(start);
        @memset(start, 'a');
        const args = try std.fmt.allocPrint(a, "{{\"path\":\"{s}é{s}\"}}", .{ start, suffix[0..] });
        defer a.free(args);
        const value = try caption(a, "read_file", args);
        defer value.deinit(a);
        try std.testing.expect(value.label.len <= 512);
        const body = try commandText(a, value, .success, " ");
        defer a.free(body);
        const row = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .success }}, 1000, null, null);
        defer a.free(row);
        try std.testing.expect(std.mem.indexOf(u8, row, "[truncated]") == null);
        try std.testing.expect(std.mem.indexOf(u8, row, "e...") == null);
        try std.testing.expect(std.mem.indexOf(u8, row, "...") != null);
        if (count == 497) try std.testing.expect(std.mem.indexOf(u8, row, "é") != null);
    }
    const literal = try caption(a, "read_file", "{\"path\":\"literal[truncated]file\"}");
    defer literal.deinit(a);
    try std.testing.expectEqualStrings("literal[truncated]file", literal.label);
}
test "all tool outcome prefixes are colored without recoloring summaries or durations" {
    const a = std.testing.allocator;
    for ([_]activity.Tool{ .bash, .read, .memory, .write }) |kind| {
        for ([_]Outcome{ .success, .failed, .canceled }) |outcome| {
            const value: Caption = .{ .kind = kind, .label = "operation target" };
            const name = activity.toolName(kind);
            const body = try commandText(a, value, outcome, " ");
            defer a.free(body);
            const label_start = commandPrefixLen(value, outcome, " ");
            const spans = &.{CommandSpan{ .start = 0, .end = body.len, .outcome = outcome, .label_start = label_start }};
            const line = try commandLine(a, body, spans, 100, 250, 0);
            defer a.free(line);
            const color = switch (outcome) {
                .success => theme.success,
                .failed => theme.failure,
                .canceled => theme.caution,
                .pending => unreachable,
            };
            const expected = try std.fmt.allocPrint(a, "{s}{s}{s}{s} {s} {s}{s}{s}{s}  250ms{s}", .{ theme.reset, color, statusGlyph(outcome), theme.tool_name, name, outcomeColor(outcome), "operation target", theme.reset, theme.duration, theme.reset });
            defer a.free(expected);
            try std.testing.expectEqualStrings(expected, line);
            // The tool name always separates the status from the command.
            try std.testing.expect(!std.mem.eql(u8, color, theme.tool_name));
            try std.testing.expect(!std.mem.eql(u8, theme.tool_name, outcomeColor(outcome)));
            try std.testing.expect(!std.mem.eql(u8, theme.thinking, color));
            try std.testing.expect(!std.mem.eql(u8, theme.thinking, outcomeColor(outcome)));
            // Three columns cannot keep the icon, so the row is dots only.
            const clipped = try commandLine(a, body, spans, 3, 250, 0);
            defer a.free(clipped);
            const clipped_expected = try std.fmt.allocPrint(a, "{s}...{s}", .{ outcomeColor(outcome), theme.reset });
            defer a.free(clipped_expected);
            try std.testing.expectEqualStrings(clipped_expected, clipped);
        }
    }
}
test "individual command rows retain their icons and own outcome prefix colors" {
    const a = std.testing.allocator;
    const body = "> date ✗ error";
    const line = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .failed }}, 79, null, null);
    defer a.free(line);
    const success = "> pwd";
    const success_line = try commandLine(a, success, &.{.{ .start = 0, .end = success.len, .outcome = .success }}, 79, null, null);
    defer a.free(success_line);
    try std.testing.expect(std.mem.find(u8, line, theme.reset ++ theme.failure ++ ">" ++ theme.failure ++ " date ✗ error") != null);
    try std.testing.expect(std.mem.find(u8, success_line, theme.reset ++ theme.success ++ ">" ++ theme.muted ++ " pwd") != null);
    try std.testing.expect(std.mem.find(u8, line, "pwd") == null);
    try std.testing.expect(std.mem.find(u8, success_line, "date") == null);
    try std.testing.expect(std.mem.findScalar(u8, line, '\n') == null);
    try std.testing.expect(std.mem.findScalar(u8, success_line, '\n') == null);
    const clipped = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .failed }}, 10, null, null);
    defer a.free(clipped);
    try std.testing.expect(std.mem.endsWith(u8, clipped, "..." ++ theme.reset));
}
