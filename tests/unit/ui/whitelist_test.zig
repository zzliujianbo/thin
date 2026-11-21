test "whitelist syntax preserves lines and links" {
    try expectScan("# Title\n\n> quote\n- [x] item\n1. **bold** _italic_ ~~gone~~ [site](https://x)\n", "Title\n\n> quote\n- [x] item\n1. bold italic gone site (https://x)\n");
    const events = try scanTest(std.testing.allocator, "**a *b* c** [z](url)", 1);
    defer std.testing.allocator.free(events);
    try std.testing.expect(events[0].bold);
    try std.testing.expect(events[2].bold and events[2].italic);
    try std.testing.expect(events[6].underline);
}
test "Chinese English strong hides delimiters and scopes bold" {
    const a = std.testing.allocator;
    const inner = "不是三 schema";
    const cases = [_]struct { source: []const u8, visible: []const u8, start: usize }{
        .{ .source = "**不是三 schema**", .visible = inner, .start = 0 },
        .{ .source = "前**不是三 schema**后", .visible = "前不是三 schema后", .start = "前".len },
    };
    for (cases) |case| {
        try expectScan(case.source, case.visible);
        const events = try scanTest(a, case.source, 1);
        defer a.free(events);
        try std.testing.expectEqual(case.visible.len, events.len);
        for (events, 0..) |event, i| {
            try std.testing.expectEqual(case.visible[i], event.byte);
            try std.testing.expectEqual(i >= case.start and i < case.start + inner.len, event.bold);
        }
    }
}
test "list markers and closed brackets preserve subsequent inline styling" {
    const input = "* **b** _i_\n- [x] ~~s~~ [l](u)\n> [ ] **b**\n[text] **b**";
    const expected = "* b i\n- [x] s l (u)\n> [ ] b\n[text] b";
    try expectScan(input, expected);
    const events = try scanTest(std.testing.allocator, input, 1);
    defer std.testing.allocator.free(events);
    const b1 = std.mem.indexOf(u8, expected, "b i").?;
    const i = b1 + 2;
    const strike = std.mem.indexOf(u8, expected, "s l").?;
    const link = strike + 2;
    const b2 = std.mem.indexOf(u8, expected, "] b\n[text]").? + 2;
    const b3 = std.mem.lastIndexOf(u8, expected, "b").?;
    try std.testing.expect(events[b1].bold and events[i].italic);
    try std.testing.expect(events[strike].strike and events[link].underline);
    try std.testing.expect(events[b2].bold and events[b3].bold);
    try std.testing.expect(!events[std.mem.indexOf(u8, expected, "[x]").?].bold);
    try expectScan("[plain] **bold**\n[x](url) [X]\n", "[plain] bold\nx (url) [X]\n");
}
test "unsupported syntax stays literal and table pipes remain visible" {
    try expectScan("![**alt**](url) `**raw**` <b>*raw*</b> $**x**$ [^a]\n| a | **b** |\n|---|---|\n", "![**alt**](url) **raw** <b>*raw*</b> $**x**$ [^a]\n| a | b |\n|---|---|\n");
    try expectScan("\\*literal\\* 中文 👩‍💻\n", "\\*literal\\* 中文 👩‍💻\n");
    try expectScan("**unclosed *not styled\nnext\n", "**unclosed *not styled\nnext\n");
}
test "table styles keep pipes padding and inline semantics across chunks" {
    const header = "| Name\\|unit | **B** `C` [L](u) |";
    const visible_header = "| Name\\|unit | B C L (u) |";
    const separator = "| :----\t| ---: |  ";
    const source = header ++ "\n" ++ separator ++ "\n| **D** | data |\ntext";
    try expectScan(source, visible_header ++ "\n" ++ separator ++ "\n| D | data |\ntext");
    const events = try scanTest(std.testing.allocator, source, 1);
    defer std.testing.allocator.free(events);
    for (events, 0..) |e, i| {
        if (i < visible_header.len) {
            const url = std.mem.indexOf(u8, visible_header, "(u)").?;
            if (i >= url - 1 and i < url + 3) { // Includes the link's synthesized space.
                try std.testing.expect(e.tone == .link_url);
            } else switch (e.byte) {
                'C' => try std.testing.expect(e.tone == .inline_code),
                'L' => try std.testing.expect(e.tone == .link and e.underline),
                else => try std.testing.expect(e.tone == .table_header),
            }
        } else if (i > visible_header.len and i <= visible_header.len + separator.len) {
            try std.testing.expect(e.tone == .muted);
        } else try std.testing.expect(e.tone == .normal);
        try std.testing.expectEqual(e.byte == 'B' or e.byte == 'D', e.bold);
    }
}

test "table recognition rejects malformed pairs and ignores fences and prose" {
    for ([_][]const u8{
        "| a | b\n|---",
        "| a\n|---|---",
        "| a\n|:--:|",
        "| a\n|---::|",
        "| a\n|-- -|",
        "| a\n|---| x",
        "| a\n---",
        "a | b\n|---|---|",
        " | a\n|---|",
        "| **B**\nnot a separator",
        "```\n| a\n|---|\n```\n",
    }) |source| {
        const events = try scanTest(std.testing.allocator, source, 1);
        defer std.testing.allocator.free(events);
        for (events) |e| {
            try std.testing.expect(e.tone != .table_header and e.tone != .muted);
            if (source[0] == '`') try std.testing.expect(e.tone == .code);
            if (e.byte == 'B') try std.testing.expect(e.bold);
        }
    }
    // Ordinary prose does not wait for the line, much less for the next one.
    try std.testing.expect(next("a", 0, 0, .{}, false) == .token);
    try std.testing.expect(next("| a\n|x", 0, 0, .{}, false) == .token);
    const pair = "| a | b\n| :---: | ---";
    for (1..pair.len + 1) |cut| try std.testing.expect(next(pair[0..cut], 0, 0, .{}, false) == .need_more);
    try std.testing.expect(next(pair, 0, 0, .{}, true).token.style.tone == .table_header);
}

test "table lookahead accepts the line limit and releases oversized candidates before EOF" {
    const a = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.append(a, '|');
    try source.appendNTimes(a, 'a', max_table_line_bytes - 1);
    try source.appendSlice(a, "\n|");
    try source.appendNTimes(a, '-', max_table_line_bytes - 1);
    try std.testing.expect(next(source.items, 0, 0, .{}, true).token.style.tone == .table_header);
    try source.append(a, '-');
    try std.testing.expect(next(source.items, 0, 0, .{}, false).token.style.tone == .normal);
    source.items[max_table_line_bytes] = 'a'; // No LF within the header cap.
    try std.testing.expect(next(source.items[0 .. max_table_line_bytes + 1], 0, 0, .{}, false).token.style.tone == .normal);
}

test "inline code is opaque and exact run matched" {
    try expectScan("x `**raw** [a](b) \\x` y", "x **raw** [a](b) \\x y");
    try expectScan("x ``a`b`` **z `**` q** [a `]` b](url)", "x a`b z ** q a ] b (url)");
    try expectScan("x `unclosed\nnext", "x `unclosed\nnext");
    try expectScan("x \\`escaped and `ok`", "x \\`escaped and ok");
    try expectScan("x `a``b`", "x a``b");
    const events = try scanTest(std.testing.allocator, "**a `x**y` z** [a `]` b](u)", 1);
    defer std.testing.allocator.free(events);
    try std.testing.expect(events[2].bold and events[2].tone == .inline_code);
    const bracket = for (events) |e| {
        if (e.byte == ']') break e;
    } else return error.MissingBracket;
    try std.testing.expect(bracket.tone == .inline_code and bracket.underline);
    const a = std.testing.allocator;
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(a);
    try long.appendSlice(a, "x `");
    try long.appendNTimes(a, 'a', max_inline_bytes + 10);
    try long.appendSlice(a, "`\n");
    try expectScan(long.items, long.items);
}
test "fences stream literally without a closing block" {
    try expectScan("```zig\n**code** [x](y)\n```\n~~after~~\n~~~\nlong code\n", "```zig\n**code** [x](y)\n```\nafter\n~~~\nlong code\n");
}
test "indented fences color matching runs without changing copied text" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "```", "~~~" }) |marker| {
        for (0..4) |open_indent| for (0..4) |close_indent| {
            const spaces = "   ";
            const src = try std.fmt.allocPrint(a, "{s}{s}zig\n A | B\n    {s}\nstill code\n{s}{s}\nplain", .{ spaces[0..open_indent], marker, marker, spaces[0..close_indent], marker });
            defer a.free(src);
            try expectScan(src, src);
            const events = try scanTest(a, src, 1);
            defer a.free(events);
            for (events[open_indent .. src.len - "plain".len]) |event| try std.testing.expectEqual(.code, event.tone);
            for (events[src.len - "plain".len ..]) |event| try std.testing.expect(event.tone != .code);
        };
        const negative = try std.fmt.allocPrint(a, "    {s}\nplain\n", .{marker});
        defer a.free(negative);
        const events = try scanTest(a, negative, 1);
        defer a.free(events);
        for (events) |event| try std.testing.expect(event.tone != .code);
    }
}

test "bounded candidate and long ordinary source" {
    const a = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    try source.appendSlice(a, "**");
    try source.appendNTimes(a, 'x', max_inline_bytes + 400);
    try source.appendSlice(a, "\n");
    try expectScan(source.items, source.items);
}
test "absolute source checkpoints survive retirement" {
    const input = "**ab `cd` ef**";
    var state: State = .{};
    var offset: usize = 0;
    var base: usize = 0;
    while (offset < input.len) {
        const step = next(input[base..], base, offset - base, state, true);
        const t = switch (step) {
            .token => |value| value,
            else => return error.UnexpectedStep,
        };
        try std.testing.expect(t.end > offset);
        offset = t.end;
        state = t.after;
        base = offset;
    }
    try std.testing.expectEqual(input.len, offset);
    try std.testing.expectEqual(@as(u8, 0), state.depth);
}
