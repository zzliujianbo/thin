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
test "subagent tool progress sanitizes and bounds borrowed captions" {
    const a = std.testing.allocator;
    const base: Caption = .{ .kind = .subagent_id, .label = "subagent_1", .failure_reason = "reason" };
    const value = try subagentProgress(a, base, " \x1b[2J中文\nnext\tline\x1b]0;secret\x07 ");
    defer value.deinit(a);
    try std.testing.expectEqualStrings("subagent_1 · 中文 next line", value.label);
    try std.testing.expectEqualStrings("reason", value.failure_reason.?);
    const empty = try subagentProgress(a, base, " \n\t");
    defer empty.deinit(a);
    try std.testing.expectEqualStrings(base.label, empty.label);
    const other = try subagentProgress(a, .{ .kind = .read, .label = "file" }, "ignored");
    defer other.deinit(a);
    try std.testing.expectEqualStrings("file", other.label);
    const long_input: [1200]u8 = @splat('x');
    const long = try subagentProgress(a, base, &long_input);
    defer long.deinit(a);
    try std.testing.expect(long.label.len <= 512 and text.width(long.label) <= 512);
    try std.testing.expect(std.unicode.utf8ValidateSlice(long.label));
    const tiny = try singleLine(a, long.label, 2);
    defer a.free(tiny);
    try std.testing.expect(text.width(tiny) <= 2);
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
    const body = try commandText(a, target, .pending);
    defer a.free(body);
    const line = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .pending }}, 80, null, null, 0);
    defer a.free(line);
    try std.testing.expect(std.mem.find(u8, line, theme.reset ++ "w" ++ theme.muted ++ " src/中文.zig") != null);
    try std.testing.expect(std.mem.find(u8, line, "⠋") == null);
    try std.testing.expect(std.mem.find(u8, line, "0ms") == null);
}
test "failed rows keep the bounded reason while the label is clipped" {
    const a = std.testing.allocator;
    const output = @import("markdown_writer.zig");
    const captioned = try fromToolView(a, "read_file", .{ .path = .{ .text = "tests/unit/app/session_host_test.zig" } });
    defer captioned.deinit(a);
    var failed = captioned;
    failed.failure_reason = "FileNotFound: file not found";
    const body = try commandText(a, failed, .failed);
    defer a.free(body);
    const tail = commandSuffixLen(failed, .failed);
    try std.testing.expect(tail != 0);
    // A wide row keeps target and reason.
    const wide = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .failed }}, 200, null, null, body.len - tail);
    defer a.free(wide);
    try std.testing.expect(std.mem.find(u8, wide, "[error] FileNotFound: file not found") != null);
    // A narrow row clips the target with dots and still names the reason.
    const narrow = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .failed }}, 60, null, null, body.len - tail);
    defer a.free(narrow);
    try std.testing.expect(std.mem.find(u8, narrow, "...") != null);
    try std.testing.expect(std.mem.find(u8, narrow, "[error] FileNotFound: file not found") != null);
    try std.testing.expect(output.displayWidth(narrow) <= commandColumns(60));
    // No room at all: the marker itself survives, never a bare letter.
    const tiny = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .failed }}, 12, null, null, body.len - tail);
    defer a.free(tiny);
    try std.testing.expect(std.mem.find(u8, tiny, "[error]") != null or std.mem.find(u8, tiny, "...") != null);
    try std.testing.expect(output.displayWidth(tiny) <= commandColumns(12));
}
test "failure reason keeps identifiers and refuses result bodies" {
    try std.testing.expectEqualStrings("AccessDenied", shared.tools.failureReason(.write, .{ .text = "AccessDenied", .is_error = true }).?);
    try std.testing.expectEqualStrings("FileNotFound: file not found", shared.tools.failureReason(.read, .{ .text = "FileNotFound", .is_error = true }).?);
    try std.testing.expect(shared.tools.failureReason(.bash, .{ .text = "{\"exit_code\":7}", .is_error = true }) == null);
    try std.testing.expect(shared.tools.failureReason(.bash, .{ .text = "Command cleanup could not be confirmed. A child may remain alive.", .is_error = true }) == null);
    try std.testing.expect(shared.tools.failureReason(.write, .{ .text = "AccessDenied", .is_error = true, .canceled = true }) == null);
    try std.testing.expect(shared.tools.failureReason(.write, .{ .text = "AccessDenied" }) == null);
}
test "bash rows show marker then command without a redundant tool name" {
    const a = std.testing.allocator;
    const early = try fromToolView(a, "bash", .{});
    defer early.deinit(a);
    const empty_body = try commandText(a, early, .pending);
    defer a.free(empty_body);
    try std.testing.expectEqualStrings("> ", empty_body);
    const ready = try fromToolView(a, "bash", .{ .command = .{ .text = "printf owned" } });
    defer ready.deinit(a);
    const canonical = try caption(a, "bash", "{\"command\":\"printf owned\"}");
    defer canonical.deinit(a);
    try std.testing.expectEqualStrings(ready.label, canonical.label);
    inline for (.{ Outcome.pending, Outcome.success, Outcome.failed, Outcome.canceled }) |outcome| {
        const body = try commandText(a, ready, outcome);
        defer a.free(body);
        try std.testing.expect(std.mem.startsWith(u8, body, "> printf owned"));
        try std.testing.expect(std.mem.find(u8, body, "> bash ") == null);
    }
    const done = try completed(a, canonical, null);
    defer done.deinit(a);
    try std.testing.expectEqualStrings("printf owned", done.label);
    // Never strip a real command's own executable named bash.
    const actual_bash = try caption(a, "bash", "{\"command\":\"bash run.sh\"}");
    defer actual_bash.deinit(a);
    const actual_body = try commandText(a, actual_bash, .pending);
    defer a.free(actual_body);
    try std.testing.expectEqualStrings("> bash run.sh", actual_body);
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
    try expectPromptSuffix(active.styled, theme.reset ++ theme.command_pulse[0] ++ "⠙" ++ theme.reset ++ " ");
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
    const edit_text = try commandText(a, edit_done, .success);
    defer a.free(edit_text);
    try std.testing.expect(std.mem.startsWith(u8, edit_text, "e "));
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
    const body = try commandText(a, known, .pending);
    defer a.free(body);
    const span: CommandSpan = .{ .start = 0, .end = body.len, .outcome = .pending, .write_marks = known.write_marks.?.shifted(2), .generating = true };
    const first = try commandLine(a, body, &.{span}, 80, null, 0, 0);
    defer a.free(first);
    const second = try commandLine(a, body, &.{span}, 80, null, 900, 0);
    defer a.free(second);
    // Generation is not execution: the icon stays in place, neutral and static,
    // and no running brightness may claim the call has started.
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.startsWith(u8, first, theme.muted ++ "w" ++ theme.muted ++ " preview.zig"));
    for (theme.tool_icon_pulse) |tone| try std.testing.expect(std.mem.indexOf(u8, first, tone) == null);
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
    const body = try commandText(a, done, .success);
    defer a.free(body);
    const span: CommandSpan = .{ .start = 0, .end = body.len, .outcome = .success, .write_marks = done.write_marks.?.shifted(2) };
    const line = try commandLine(a, body, &.{span}, 200, null, null, 0);
    defer a.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, theme.reset ++ theme.success ++ "w" ++ theme.muted ++ " path +99 -88 中文  ~4 "));
    try std.testing.expect(std.mem.indexOf(u8, line, theme.diff_added ++ "+12" ++ theme.muted) != null);
    try std.testing.expect(std.mem.indexOf(u8, line, theme.diff_removed ++ "-34" ++ theme.muted) != null);
    for ([_]usize{ 1, 4, 20, 45, 55 }) |columns| {
        const clipped = try commandLine(a, body, &.{span}, columns, null, null, 0);
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
                const suffix = try std.fmt.allocPrint(a, ") {s}{s}{s}{s}{s}{s} ", .{ case.color, case.label, theme.reset, if (busy) theme.command_pulse[0] else "", if (busy) activity.spinner(80) else ">", if (busy) theme.reset else "" });
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
        const suffix = try std.fmt.allocPrint(a, ") {s}{s}{s}{s}{s}{s}{s} ", .{ case.color, if (enabled) "L" else "", case.label, theme.reset, if (busy) theme.command_pulse[0] else "", if (busy) activity.spinner(80) else ">", if (busy) theme.reset else "" });
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
                try expected.writer.print("{s}) {s}2.3%{s}{s}{s}{s} ", .{ theme.reset, theme.success, theme.reset, theme.command_pulse[shared.activity.commandStep(now)], activity.spinner(now), theme.reset });
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
                    try expectPromptStyle(theme.command_pulse[0] ++ "⠙" ++ theme.reset ++ " ", narrow.styled);
                } else try expectPromptStyle(narrow.plain, narrow.styled);
            }
        }
    }
}
test "composer busy marker keeps its own braille pulse while tool rows breathe separately" {
    try text.initLocale();
    const a = std.testing.allocator;
    for ([_]u64{ 0, 79, 80, 119, 120, 239, 960, std.math.maxInt(u64) }) |now| {
        const color = theme.command_pulse[shared.activity.commandStep(now)];
        const icon = activity.spinner(now);
        const ending = try std.fmt.allocPrint(a, "{s}{s}{s} ", .{ color, icon, theme.reset });
        defer a.free(ending);
        const tool_prefix = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ theme.toolIconColor(now), ">", theme.muted });
        defer a.free(tool_prefix);
        const tool = try commandLine(a, "> target", &.{.{ .start = 0, .end = 8, .outcome = .pending }}, 80, null, now, 0);
        defer a.free(tool);
        try std.testing.expect(std.mem.startsWith(u8, tool, tool_prefix));
        for ([_]usize{ 0, 7, 12, 15, 80 }) |columns| for ([_]shared.activity.RateBand{ .slow, .fast, .unknown }) |band| {
            const rendered = try prompt(a, "model", .{ .tokens = 10, .limit = 100 }, columns, .{ .busy = true, .streaming = true, .now_ms = now, .phase = 7, .rate_band = band, .reasoning_effort = .high });
            defer rendered.deinit(a);
            try expectPromptSuffix(rendered.styled, ending);
            try std.testing.expectEqual(text.width(rendered.plain), @import("markdown_writer.zig").displayWidth(rendered.styled));
            try std.testing.expect(text.width(rendered.plain) <= @max(columns, 2));
        };
    }
}
test "all four tool icons breathe warm while glyph, column and width stay fixed" {
    try text.initLocale();
    const a = std.testing.allocator;
    for ([_]activity.Tool{ .bash, .read, .write, .memory }) |kind| {
        const value: Caption = .{ .kind = kind, .label = "operation target" };
        const body = try commandText(a, value, .pending);
        defer a.free(body);
        const spans = &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .pending }};
        for ([_]u64{ 0, 80, 180, 360 }) |time| {
            const line = try commandLine(a, body, spans, 100, null, time, 0);
            defer a.free(line);
            const prefix = try std.fmt.allocPrint(a, "{s}{s}{s} operation target{s}", .{ theme.toolIconColor(time), activity.icon(kind), theme.muted, theme.reset });
            defer a.free(prefix);
            try std.testing.expectEqualStrings(prefix, line);
        }
        const done = try commandLine(a, body, &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .success }}, 100, null, 120, 0);
        defer a.free(done);
        const expected = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ theme.reset ++ theme.success, activity.icon(kind), theme.muted, body[activity.icon(kind).len..], theme.reset });
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, done);
    }
    try std.testing.expectEqualStrings("r", activity.icon(.read));
    try std.testing.expectEqualStrings("w", activity.icon(.write));
    try std.testing.expectEqualStrings("m", activity.icon(.memory));
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
        const body = try commandText(a, value, .pending);
        defer a.free(body);
        for ([_]usize{ 0, 1, 4, 10, 80, 200, 512 }) |columns| {
            const line = try commandLine(a, body, &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .pending }}, columns, null, 80, 0);
            defer a.free(line);
            try std.testing.expect(output.displayWidth(line) <= commandColumns(columns));
            try std.testing.expect(std.unicode.utf8ValidateSlice(line));
            if (columns >= 10 and columns <= 200) try std.testing.expect(std.mem.endsWith(u8, line, "..." ++ theme.reset));
        }
    }
    const body = "r 中文é repeated-path 中文é repeated-path 中文é repeated-path";
    const line = try commandLine(a, body, &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .pending }}, 80, null, 120, 0);
    defer a.free(line);
    try std.testing.expect(output.displayWidth(line) <= 80);
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    try std.testing.expectEqual(@as(usize, 100), commandColumns(100));
    try std.testing.expectEqual(@as(usize, 79), commandColumns(79));
    for (0..128) |columns| try std.testing.expectEqual(columns, commandColumns(columns));
    try std.testing.expect(commandColumns(std.math.maxInt(usize)) <= std.math.maxInt(usize));
    const memory = try caption(a, "memory", "{\"action\":\"write\",\"topic\":\"core\",\"content\":\"hidden-body\"}");
    defer memory.deinit(a);
    try std.testing.expectEqualStrings("write core", memory.label);
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
        const body = try commandText(a, .{ .kind = .bash, .label = "echo 中文é very-long-command 中文é very-long-command 中文é tail" }, outcome);
        defer a.free(body);
        for (cases) |case| {
            const ending = try std.fmt.allocPrint(a, "  {s}{s}", .{ case.suffix, theme.reset });
            defer a.free(ending);
            for ([_]usize{ 0, 1, 7, 12, 16, 40, 79, 200 }) |columns| {
                const line = try commandLine(a, body, &.{CommandSpan{ .start = 0, .end = body.len, .outcome = outcome }}, columns, case.ms, 120, 0);
                defer a.free(line);
                try std.testing.expect(output.displayWidth(line) <= commandColumns(columns));
                try std.testing.expect(std.unicode.utf8ValidateSlice(line));
                if (commandColumns(columns) >= case.suffix.len + 6) try std.testing.expect(std.mem.endsWith(u8, line, ending));
            }
        }
    }
}
test "only the executing tool icon breathes while completed spans stay static and clipped safely" {
    const a = std.testing.allocator;
    const body = "> sleep 1";
    const spans = &.{CommandSpan{ .start = 0, .end = body.len, .outcome = .pending }};
    const first = try commandLine(a, body, spans, 79, null, 0, 0);
    defer a.free(first);
    const second = try commandLine(a, body, spans, 79, null, 180, 0);
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expect(std.mem.find(u8, first, theme.tool_icon_pulse[0] ++ ">" ++ theme.muted ++ " sleep 1") != null);
    // A clip that eats the icon cannot fabricate one: no prefix, no breathing.
    const narrow = try commandLine(a, "r long-path", &.{CommandSpan{ .start = 0, .end = "r long-path".len, .outcome = .pending }}, 3, null, 1, 0);
    defer a.free(narrow);
    try std.testing.expect(std.unicode.utf8ValidateSlice(narrow));
    try std.testing.expectEqualStrings(theme.muted ++ "..." ++ theme.reset, narrow);
    for ([_]Outcome{ .success, .failed, .canceled }) |outcome| {
        const complete = &.{CommandSpan{ .start = 0, .end = body.len, .outcome = outcome }};
        const one = try commandLine(a, body, complete, 79, null, 0, 0);
        defer a.free(one);
        const two = try commandLine(a, body, complete, 79, null, 180, 0);
        defer a.free(two);
        try std.testing.expectEqualStrings(one, two);
    }
}
test "executing icon keeps one glyph and column across phases while only brightness moves" {
    try text.initLocale();
    const a = std.testing.allocator;
    const times = [_]u64{ 0, 179, 180, 360, 540, 720, 900, 1080, std.math.maxInt(u64) };
    for ([_]activity.Tool{ .bash, .read, .write, .memory, .subagent, .other }) |kind| {
        const value: Caption = .{ .kind = kind, .label = "operation 中文 target" };
        const body = try commandText(a, value, .pending);
        defer a.free(body);
        const icon = body[0..activity.icon(kind).len];
        const done = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .success }}, 80, 250, 900, 0);
        defer a.free(done);
        const done_visible = try visibleRow(a, done);
        defer a.free(done_visible);
        var tones: [theme.tool_icon_pulse.len][]const u8 = undefined;
        var tone_count: usize = 0;
        for (times) |now| {
            const line = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .pending }}, 80, 250, now, 0);
            defer a.free(line);
            const tone = theme.toolIconColor(now);
            // Only brightness moves: same glyph bytes, same column, same width.
            try std.testing.expectEqualStrings(tone, line[0..tone.len]);
            try std.testing.expectEqualStrings(icon, line[tone.len .. tone.len + icon.len]);
            try std.testing.expect(std.mem.startsWith(u8, line[tone.len + icon.len ..], theme.muted));
            const visible = try visibleRow(a, line);
            defer a.free(visible);
            // Stripping SGR leaves exactly the finished row's text: same icon,
            // same column, same caption and the same measured timer suffix.
            try std.testing.expectEqualStrings(done_visible, visible);
            try std.testing.expectEqual(text.styledWidth(done), text.styledWidth(line));
            var known = false;
            for (tones[0..tone_count]) |seen| known = known or std.mem.eql(u8, seen, tone);
            if (!known) {
                tones[tone_count] = tone;
                tone_count += 1;
            }
        }
        // A finite warm ramp, never a running character or a blinking cell.
        try std.testing.expect(tone_count >= 4);
        try std.testing.expect(std.mem.indexOf(u8, body, "⠋") == null);
        // Generation is not execution: the same icon stays put but neutral and
        // static, and it never borrows a running brightness or a timer.
        for ([_]u64{ 0, 180, 900, std.math.maxInt(u64) }) |now| {
            const generating = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .pending, .generating = true }}, 80, null, now, 0);
            defer a.free(generating);
            const expected = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ theme.muted, icon, theme.muted, body[icon.len..], theme.reset });
            defer a.free(expected);
            try std.testing.expectEqualStrings(expected, generating);
            for (theme.tool_icon_pulse) |tone| try std.testing.expect(std.mem.indexOf(u8, generating, tone) == null);
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
        const body = try commandText(a, value, .success);
        defer a.free(body);
        const row = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .success }}, 1000, null, null, 0);
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
            const body = try commandText(a, value, outcome);
            defer a.free(body);
            const spans = &.{CommandSpan{ .start = 0, .end = body.len, .outcome = outcome }};
            const line = try commandLine(a, body, spans, 100, 250, 0, 0);
            defer a.free(line);
            const color = switch (outcome) {
                .success => theme.success,
                .failed => theme.failure,
                .canceled => theme.caution,
                .pending => unreachable,
            };
            const expected = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}{s}{s}  250ms{s}", .{ theme.reset, color, activity.icon(kind), outcomeColor(outcome), body[activity.icon(kind).len..], theme.reset, theme.duration, theme.reset });
            defer a.free(expected);
            try std.testing.expectEqualStrings(expected, line);
            try std.testing.expect(!std.mem.eql(u8, theme.thinking, color));
            try std.testing.expect(!std.mem.eql(u8, theme.thinking, outcomeColor(outcome)));
            // Three columns cannot keep the icon, so the row is dots only.
            const clipped = try commandLine(a, body, spans, 3, 250, 0, 0);
            defer a.free(clipped);
            const clipped_expected = try std.fmt.allocPrint(a, "{s}...{s}", .{ outcomeColor(outcome), theme.reset });
            defer a.free(clipped_expected);
            try std.testing.expectEqualStrings(clipped_expected, clipped);
        }
    }
}
test "individual command rows retain their icons and own outcome prefix colors" {
    const a = std.testing.allocator;
    const body = "> date [error]";
    const line = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .failed }}, 79, null, null, 0);
    defer a.free(line);
    const success = "> pwd";
    const success_line = try commandLine(a, success, &.{.{ .start = 0, .end = success.len, .outcome = .success }}, 79, null, null, 0);
    defer a.free(success_line);
    try std.testing.expect(std.mem.find(u8, line, theme.reset ++ theme.failure ++ ">" ++ theme.failure ++ " date [error]") != null);
    try std.testing.expect(std.mem.find(u8, success_line, theme.reset ++ theme.success ++ ">" ++ theme.muted ++ " pwd") != null);
    try std.testing.expect(std.mem.find(u8, line, "pwd") == null);
    try std.testing.expect(std.mem.find(u8, success_line, "date") == null);
    try std.testing.expect(std.mem.findScalar(u8, line, '\n') == null);
    try std.testing.expect(std.mem.findScalar(u8, success_line, '\n') == null);
    const clipped = try commandLine(a, body, &.{.{ .start = 0, .end = body.len, .outcome = .failed }}, 10, null, null, 0);
    defer a.free(clipped);
    try std.testing.expect(std.mem.endsWith(u8, clipped, "..." ++ theme.reset));
}
