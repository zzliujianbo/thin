const TestEvent = struct { byte: u8, tone: @import("markdown_writer.zig").Tone, bold: bool, italic: bool, strike: bool, underline: bool };

fn scanTest(a: std.mem.Allocator, input: []const u8, chunk: usize) ![]TestEvent {
    var events: std.ArrayList(TestEvent) = .empty;
    errdefer events.deinit(a);
    var state: State = .{};
    var cursor: usize = 0;
    var available: usize = 0;
    var iterations: usize = 0;
    while (true) {
        iterations += 1;
        if (iterations > input.len * 8 + 100) return error.ScannerDidNotProgress;
        switch (next(input[0..available], 0, cursor, state, available == input.len)) {
            .token => |t| {
                if (t.end <= cursor or t.end > available) return error.InvalidSourceRange;
                for (t.text) |byte| try events.append(a, .{ .byte = byte, .tone = t.style.tone, .bold = t.style.bold, .italic = t.style.italic, .strike = t.style.strike, .underline = t.style.underline });
                cursor = t.end;
                state = t.after;
            },
            .need_more => {
                if (available == input.len) return error.UnexpectedNeedMore;
                available = @min(input.len, available + chunk);
                // The scanner's contract is sanitized, complete UTF-8 scalars.
                while (available < input.len and input[available] & 0xc0 == 0x80) : (available += 1) {}
            },
            .end => {
                try std.testing.expectEqual(input.len, cursor);
                return events.toOwnedSlice(a);
            },
        }
    }
}

fn expectScan(input: []const u8, expected: []const u8) !void {
    const a = std.testing.allocator;
    const batch = try scanTest(a, input, @max(input.len, 1));
    defer a.free(batch);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    for (batch) |e| try bytes.append(a, e.byte);
    try std.testing.expectEqualStrings(expected, bytes.items);
    for ([_]usize{ 1, 2, 3, 7, 31 }) |size| {
        const incremental = try scanTest(a, input, size);
        defer a.free(incremental);
        try std.testing.expectEqualDeep(batch, incremental);
    }
}
