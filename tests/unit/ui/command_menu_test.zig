test "slash suggestions preserve model login compact order and support local fuzzy search" {
    const all = suggestions("/", 1, false);
    try std.testing.expectEqual(items.len, all.len);
    try std.testing.expectEqual(Command.model, all.commands[0]);
    try std.testing.expectEqual(Command.auth, all.commands[1]);
    try std.testing.expectEqual(Command.compact, all.commands[2]);
    try std.testing.expectEqual(Command.settings, all.commands[3]);
    for ([_][]const u8{ "/CPT", "/compact" }) |query| {
        const found = suggestions(query, query.len, false);
        try std.testing.expectEqual(@as(usize, 1), found.len);
        try std.testing.expectEqual(Command.compact, found.commands[0]);
    }
    // /co now genuinely prefixes /compact and /close; both stay candidates.
    const co = suggestions("/co", 3, false);
    try std.testing.expectEqual(@as(usize, 2), co.len);
    try std.testing.expectEqual(Command.compact, co.commands[0]);
    try std.testing.expectEqual(Command.close, co.commands[1]);
    for ([_][]const u8{ "/mo", "/MD", "/model" }) |query| {
        const found = suggestions(query, query.len, false);
        try std.testing.expectEqual(@as(usize, 1), found.len);
        try std.testing.expectEqual(Command.model, found.commands[0]);
    }
    const auth = suggestions("/lgn", 4, false);
    try std.testing.expectEqual(@as(usize, 1), auth.len);
    try std.testing.expectEqual(Command.auth, auth.commands[0]);
    for ([_][]const u8{ "/ls", "/cd", "/attach", "/detach", "/exit" }) |query| {
        const found = suggestions(query, query.len, false);
        try std.testing.expect(found.len >= 1);
        // Subsequence matching may offer extra candidates (/ls also matches
        // /close); the exact command must always be present.
        var hit = false;
        for (found.commands[0..found.len]) |command| {
            if (std.mem.eql(u8, info(command).value, query)) hit = true;
        }
        try std.testing.expect(hit);
    }
}
test "resume is a remote root candidate and completes to its exact command" {
    const matches = suggestions("/res", 4, false);
    var found = false;
    for (matches.commands[0..matches.len]) |command| {
        if (command == .@"resume") {
            found = true;
            try std.testing.expectEqualStrings("/resume", info(command).value);
        }
    }
    try std.testing.expect(found);
    try std.testing.expect(sessionOnly(.@"resume"));
}
test "session commands are classified apart from local commands" {
    try std.testing.expect(!sessionOnly(.model) and !sessionOnly(.auth) and !sessionOnly(.compact) and !sessionOnly(.settings));
    for ([_]Command{ .sessions, .cd, .attach, .detach, .close, .exit }) |command| try std.testing.expect(sessionOnly(command));
}
test "slash suggestions exclude arguments multiline prompts paste and mid-token cursor" {
    for ([_][]const u8{ "", "hello /", " /model", "/login key", "/model\n", "/unknown", "/../", "/compact now", "/压缩", "/compact1" }) |value|
        try std.testing.expectEqual(@as(usize, 0), suggestions(value, value.len, false).len);
    try std.testing.expectEqual(@as(usize, 0), suggestions("/login", 6, true).len);
    try std.testing.expectEqual(@as(usize, 0), suggestions("/model", 3, false).len);
}
test "command rows are bounded clipped and mark the selection" {
    const a = std.testing.allocator;
    const all = suggestions("/", 1, false);
    const rendered = try rows(a, all, 1, 24, 8);
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expectEqual(@as(usize, 8), rendered.lines.len);
    try std.testing.expect(rendered.can_confirm);
    try std.testing.expectEqual(@as(usize, 1), rendered.selected_line.?);
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[1], "> ") != null);
    for (rendered.lines) |line| try std.testing.expect(text.width(line) <= 24);
    const none = try rows(a, .{}, 0, 24, 8);
    defer a.free(none.lines);
    try std.testing.expectEqual(@as(usize, 0), none.lines.len);
}
test "command rows show optional arguments and descriptions" {
    const a = std.testing.allocator;
    const rendered = try rows(a, suggestions("/", 1, false), 0, 80, 8);
    defer {
        for (rendered.lines) |line| a.free(line);
        a.free(rendered.lines);
    }
    try std.testing.expectEqualStrings("> /model [exact-id|--refresh]  Select model", rendered.lines[0]);
    try std.testing.expectEqualStrings("  /login                       Configure provider", rendered.lines[1]);
    try std.testing.expectEqualStrings("  /compact                     Compact conversation", rendered.lines[2]);
    try std.testing.expectEqualStrings("", info(.auth).arguments);
    try std.testing.expectEqualStrings("", info(.compact).arguments);
}
test "command rows clean up every allocation failure" {
    const Check = struct {
        fn render(a: std.mem.Allocator) !void {
            const rendered = try rows(a, suggestions("/", 1, false), 1, 80, 8);
            defer {
                for (rendered.lines) |line| a.free(line);
                a.free(rendered.lines);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.render, .{});
}
test "command descriptions align across selections windows filters and clipping" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "/", "/o", "/lgn", "/co" }) |query| {
        const matches = suggestions(query, query.len, false);
        var label_width: usize = 0;
        for (matches.commands[0..matches.len]) |command| {
            const item = info(command);
            label_width = @max(label_width, text.width(item.value) + if (item.arguments.len != 0) 1 + text.width(item.arguments) else @as(usize, 0));
        }
        const description_column = 2 + label_width + 2;
        for (matches.commands[0..matches.len], 0..) |_, selected| {
            for ([_]usize{ 1, items.len }) |height| {
                for ([_]usize{ 0, 8, description_column - 1, description_column, description_column + 3, 80 }) |columns| {
                    const rendered = try rows(a, matches, selected, columns, height);
                    defer {
                        for (rendered.lines) |line| a.free(line);
                        a.free(rendered.lines);
                    }
                    const count = @min(matches.len, @min(height, 10));
                    const start = @min(selected -| (count / 2), matches.len - count);
                    try std.testing.expectEqual(selected - start, rendered.selected_line.?);
                    for (rendered.lines, start..) |line, index| {
                        const item = info(matches.commands[index]);
                        try std.testing.expectEqual(@min(columns, description_column + text.width(item.description)), text.width(line));
                        try std.testing.expect(std.mem.indexOfScalar(u8, line, '\t') == null);
                        if (columns > description_column) {
                            const visible = @min(columns - description_column, item.description.len);
                            try std.testing.expectEqualStrings(item.description[0..visible], line[description_column..]);
                            if (columns == 80) {
                                const offset = std.mem.indexOf(u8, line, item.description).?;
                                try std.testing.expectEqual(description_column, text.width(line[0..offset]));
                            }
                        }
                    }
                }
            }
        }
    }
}
test "command confirmation needs only the complete command and keeps selection in a narrow window" {
    const a = std.testing.allocator;
    const all = suggestions("/", 1, false);
    for (all.commands[0..all.len], 0..) |command, selected| {
        const command_width = 2 + text.width(info(command).value);
        for (0..command_width + 3) |width| {
            const rendered = try rows(a, all, selected, width, 1);
            defer {
                for (rendered.lines) |line| a.free(line);
                a.free(rendered.lines);
            }
            try std.testing.expectEqual(@as(usize, 1), rendered.lines.len);
            try std.testing.expectEqual(@as(usize, 0), rendered.selected_line.?);
            try std.testing.expect(text.width(rendered.lines[0]) <= width);
            try std.testing.expectEqual(width >= command_width, rendered.can_confirm);
            if (width == command_width) {
                try std.testing.expectEqualStrings(info(command).value, rendered.lines[0][2..]);
            }
        }
    }
    try text.initLocale();
    const clipped = try singleLine(a, "中a文", 4);
    defer a.free(clipped);
    try std.testing.expectEqualStrings("中a", clipped);
}
test "command rows never authorize a hidden or clipped command" {
    const a = std.testing.allocator;
    const all = suggestions("/", 1, false);
    for (0..4) |height| {
        for (0..10) |width| {
            const rendered = try rows(a, all, 1, width, height);
            defer {
                for (rendered.lines) |line| a.free(line);
                a.free(rendered.lines);
            }
            try std.testing.expect(rendered.lines.len <= height);
            for (rendered.lines) |line| try std.testing.expect(text.width(line) <= width);
            try std.testing.expectEqual(height >= 1 and width >= 8, rendered.can_confirm);
            if (rendered.can_confirm) try std.testing.expect(std.mem.find(u8, rendered.lines[rendered.selected_line.?], "> /login") != null);
        }
    }
}
test "slash selection wraps and dismissal lasts until an edit" {
    var menu: Menu = .{};
    const all = suggestions("/", 1, false);
    menu.move(false, all.len);
    try std.testing.expectEqual(Command.exit, menu.choice(all).?);
    menu.move(true, all.len);
    try std.testing.expectEqual(Command.model, menu.choice(all).?);
    menu.move(true, all.len);
    try std.testing.expectEqual(Command.auth, menu.choice(all).?);
    menu.move(true, all.len);
    try std.testing.expectEqual(Command.compact, menu.choice(all).?);
    const generation = menu.generation;
    menu.dismiss();
    try std.testing.expect(menu.generation != generation and menu.choice(all) == null);
    menu.changed();
    try std.testing.expectEqual(Command.model, menu.choice(all).?);
    try std.testing.expectEqualStrings("/login", info(.auth).value);
}
