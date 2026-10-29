//! Deterministic, allocation-free scanner for the terminal Markdown whitelist.
//! All positions retained in State are absolute sanitized-source byte offsets.
const std = @import("std");
const Style = @import("markdown_writer.zig").Style;

pub const max_inline_bytes: usize = 2048;
const depth_limit = 8;
const Kind = enum { strong, italic, strike, link };
const Frame = struct {
    kind: Kind = .italic,
    close: usize = 0,
    close_len: u8 = 0,
    url_end: usize = 0,
    url: bool = false,
};
pub const State = struct {
    at_line_start: bool = true,
    fence: u8 = 0,
    fence_len: usize = 0,
    fence_header: bool = false,
    fence_run: bool = false,
    fence_closing: bool = false,
    fence_count: usize = 0,
    fence_spaces: bool = false,
    heading: bool = false,
    quote: bool = false,
    escaped: bool = false,
    literal_until: usize = 0,
    depth: u8 = 0,
    frames: [depth_limit]Frame = @splat(.{}),
};
pub const Token = struct {
    text: []const u8,
    start: usize,
    end: usize,
    style: Style,
    after: State,
    exact: bool = true,
};
pub const Step = union(enum) { token: Token, need_more, end };

fn style(s: State) Style {
    var out: Style = .{};
    if (s.fence != 0) out.tone = .code else if (s.heading) out.tone = .heading else if (s.quote) out.tone = .quote;
    for (s.frames[0..s.depth]) |frame| switch (frame.kind) {
        .strong => out.bold = true,
        .italic => out.italic = true,
        .strike => out.strike = true,
        .link => {
            out.tone = if (frame.url) .link_url else .link;
            out.underline = !frame.url;
        },
    };
    return out;
}
fn token(source: []const u8, base: usize, offset: usize, n: usize, s: State, visible: []const u8, exact: bool) Step {
    _ = source;
    return .{ .token = .{ .text = visible, .start = base + offset, .end = base + offset + n, .style = style(s), .after = s, .exact = exact } };
}
fn scalarLen(byte: u8) usize {
    return if (byte < 0x80) 1 else if (byte < 0xe0) 2 else if (byte < 0xf0) 3 else 4;
}
fn consume(source: []const u8, base: usize, offset: usize, s: State) Step {
    const n = scalarLen(source[offset]);
    return token(source, base, offset, n, s, source[offset .. offset + n], true);
}
fn boundary(source: []const u8, offset: usize, final: bool, parent_end: ?usize, base: usize) struct { end: usize, decisive: bool } {
    var end = offset;
    const cap = offset +| max_inline_bytes;
    const stop = @min(source.len, cap);
    while (end < stop and source[end] != '\n' and (parent_end == null or base + end < parent_end.?)) : (end += 1) {}
    // A cap landing in a UTF-8 scalar is rounded down: never split a scalar.
    while (end > offset and end < source.len and source[end] & 0xc0 == 0x80) : (end -= 1) {}
    return .{ .end = end, .decisive = end < source.len or source.len >= cap or final or (parent_end != null and base + end >= parent_end.?) };
}
fn escapedAt(source: []const u8, pos: usize, begin: usize) bool {
    var p = pos;
    while (p > begin and source[p - 1] == '\\') : (p -= 1) {}
    return (pos - p) % 2 != 0;
}
fn matchAt(source: []const u8, pos: usize, end: usize, marker: []const u8, begin: usize) bool {
    return pos + marker.len <= end and std.mem.eql(u8, source[pos .. pos + marker.len], marker) and !escapedAt(source, pos, begin);
}
fn findMarker(source: []const u8, start: usize, end: usize, marker: []const u8) ?usize {
    var i = start;
    while (i + marker.len <= end) : (i += 1) {
        if (matchAt(source, i, end, marker, start)) return i;
    }
    return null;
}
fn literal(source: []const u8, base: usize, offset: usize, state: State, end: usize) Step {
    var s = state;
    s.literal_until = base + @max(end, offset + scalarLen(source[offset]));
    s.at_line_start = false;
    return consume(source, base, offset, s);
}

/// source contains valid, already sanitized UTF-8. offset is a scalar boundary.
/// Tokens cover monotonically increasing source; empty tokens consume syntax.
pub fn next(source: []const u8, base: usize, offset: usize, state: State, final: bool) Step {
    if (offset >= source.len) return if (final) .end else .need_more;
    const absolute = base + offset;
    const ch = source[offset];
    var s = state;

    if (s.fence != 0) {
        // Opening and closing fence runs are tracked while their literal bytes
        // are emitted; only the newline commits a possible closing line.
        if (s.fence_header) {
            if (s.fence_run and ch == s.fence) s.fence_len += 1 else s.fence_run = false;
        } else if (s.at_line_start) {
            s.fence_closing = ch == s.fence;
            s.fence_count = if (s.fence_closing) 1 else 0;
            s.fence_spaces = false;
        } else if (s.fence_closing and ch != '\n') {
            if (!s.fence_spaces and ch == s.fence) s.fence_count += 1 else if (ch == ' ' or ch == '\t') {
                s.fence_spaces = true;
            } else s.fence_closing = false;
        }
        const emitted_style = style(s);
        if (ch == '\n') {
            if (!s.fence_header and s.fence_closing and s.fence_count >= s.fence_len) s.fence = 0;
            s.fence_header = false;
            s.fence_run = false;
            s.fence_closing = false;
            s.at_line_start = true;
        } else s.at_line_start = false;
        const n = scalarLen(ch);
        return .{ .token = .{ .text = source[offset .. offset + n], .start = absolute, .end = absolute + n, .style = emitted_style, .after = s } };
    }
    if (ch == '\n') {
        s.at_line_start = true;
        s.heading = false;
        s.quote = false;
        s.escaped = false;
        s.literal_until = 0;
        s.depth = 0;
        return consume(source, base, offset, s);
    }
    if (absolute < s.literal_until) {
        s.at_line_start = false;
        return consume(source, base, offset, s);
    }
    if (s.escaped) {
        s.escaped = false;
        s.at_line_start = false;
        return consume(source, base, offset, s);
    }
    if (s.depth > 0) {
        const frame = s.frames[s.depth - 1];
        if (absolute == frame.close) {
            if (frame.kind == .link and !frame.url) {
                s.frames[s.depth - 1].url = true;
                s.frames[s.depth - 1].close = frame.url_end;
                return token(source, base, offset, 1, s, " ", false);
            }
            const before = style(s);
            s.depth -= 1;
            if (frame.kind == .link) return .{ .token = .{ .text = source[offset .. offset + 1], .start = absolute, .end = absolute + 1, .style = before, .after = s } };
            return token(source, base, offset, frame.close_len, s, "", false);
        }
        // URL is displayed literally, including parentheses.
        if (frame.kind == .link and frame.url) return consume(source, base, offset, s);
    }
    if (s.at_line_start) {
        if (ch == '*') {
            if (offset + 1 == source.len and !final) return .need_more;
            if (offset + 1 < source.len and (source[offset + 1] == ' ' or source[offset + 1] == '\t')) {
                s.at_line_start = false;
                return consume(source, base, offset, s);
            }
        }
        if (ch == '#' or ch == '`' or ch == '~') {
            var run: usize = 0;
            const limit: usize = if (ch == '#') 7 else 3;
            while (offset + run < source.len and run < limit and source[offset + run] == ch) : (run += 1) {}
            if (offset + run == source.len and run < limit and !final) return .need_more;
            if (ch == '#' and run >= 1 and run <= 6) {
                if (offset + run == source.len and !final) return .need_more;
                if (offset + run < source.len and source[offset + run] == ' ') {
                    s.heading = true;
                    s.at_line_start = false;
                    return token(source, base, offset, run + 1, s, "", false);
                }
            }
            if ((ch == '`' or ch == '~') and run == 3) {
                s.fence = ch;
                s.fence_len = 1;
                s.fence_header = true;
                s.fence_run = true;
                s.at_line_start = false;
                return consume(source, base, offset, s);
            }
        }
        if (ch == '>') s.quote = true;
        s.at_line_start = false;
    }
    if (ch == '\\') {
        s.escaped = true;
        return consume(source, base, offset, s);
    }
    // A non-image exclamation mark is ordinary; only its next byte matters.
    if (ch == '!') {
        if (offset + 1 == source.len and !final) return .need_more;
        if (offset + 1 == source.len or source[offset + 1] != '[') return consume(source, base, offset, s);
    }
    // Ordinary characters have no lookahead: long plain lines remain linear.
    switch (ch) {
        '<', '!', '[', '`', '$', '*', '_', '~' => {},
        else => return consume(source, base, offset, s),
    }
    const parent_end: ?usize = if (s.depth == 0) null else s.frames[s.depth - 1].close;
    const bounds = boundary(source, offset, final, parent_end, base);
    const end = bounds.end;

    // Protect the contents of a simple paired HTML element as well as its tags.
    // This deliberately does not attempt a general HTML grammar.
    if (ch == '<' and offset + 1 < end and std.ascii.isAlphabetic(source[offset + 1])) {
        var name_end = offset + 2;
        while (name_end < end and (std.ascii.isAlphanumeric(source[name_end]) or source[name_end] == '-')) : (name_end += 1) {}
        if (findMarker(source, name_end, end, ">")) |opening_end| {
            if (opening_end > offset and source[opening_end - 1] == '/') return literal(source, base, offset, s, opening_end + 1);
            var p = opening_end + 1;
            while (p + 2 + name_end - offset - 1 <= end) : (p += 1) {
                const name = source[offset + 1 .. name_end];
                if (source[p] == '<' and source[p + 1] == '/' and p + 2 + name.len < end and std.mem.eql(u8, source[p + 2 .. p + 2 + name.len], name) and source[p + 2 + name.len] == '>') return literal(source, base, offset, s, p + 3 + name.len);
            }
        }
        if (!bounds.decisive) return .need_more;
        return literal(source, base, offset, s, end);
    }
    // Unsupported constructs are opaque literal regions. A bounded unterminated
    // region is frozen literally, not recursively reinterpreted.
    if (ch == '!' and offset + 1 == source.len and !final) return .need_more;
    if (ch == '`' or ch == '$' or ch == '<' or (ch == '!' and offset + 1 < source.len and source[offset + 1] == '[') or (ch == '[' and offset + 1 < source.len and source[offset + 1] == '^')) {
        const image = ch == '!';
        const footnote = ch == '[';
        const closing: []const u8 = if (image) ")" else if (footnote) "]" else if (ch == '<') ">" else source[offset .. offset + 1];
        const search = offset + if (image or footnote) @as(usize, 2) else 1;
        if (findMarker(source, search, end, closing)) |close| return literal(source, base, offset, s, close + closing.len);
        if (!bounds.decisive) return .need_more;
        return literal(source, base, offset, s, end);
    }
    if (ch == '[') {
        if (findMarker(source, offset + 1, end, "]")) |middle| {
            // A `]` at the current chunk edge can still be followed by `(`.
            if (middle + 1 == end) {
                if (!bounds.decisive) return .need_more;
                return literal(source, base, offset, s, middle + 1);
            }
            if (source[middle + 1] != '(') return literal(source, base, offset, s, middle + 1);
            if (findMarker(source, middle + 2, end, ")")) |close| {
                if (s.depth < depth_limit) {
                    s.frames[s.depth] = .{ .kind = .link, .close = base + middle, .close_len = 1, .url_end = base + close };
                    s.depth += 1;
                    return token(source, base, offset, 1, s, "", false);
                }
                return literal(source, base, offset, s, close + 1);
            }
        }
        if (!bounds.decisive) return .need_more;
        return literal(source, base, offset, s, end);
    }
    if (ch == '*' or ch == '_' or ch == '~') {
        if (offset + 1 == source.len and !final) return .need_more;
        const doubled = offset + 1 < source.len and source[offset + 1] == ch;
        if (ch == '~' and !doubled) return consume(source, base, offset, s);
        const n: usize = if (doubled) 2 else 1;
        const marker = source[offset .. offset + n];
        if (findMarker(source, offset + n, end, marker)) |close| {
            if (close == offset + n) return literal(source, base, offset, s, close + n);
            if (s.depth < depth_limit) {
                s.frames[s.depth] = .{ .kind = if (ch == '~') .strike else if (doubled) .strong else .italic, .close = base + close, .close_len = @intCast(n) };
                s.depth += 1;
                return token(source, base, offset, n, s, "", false);
            }
            return literal(source, base, offset, s, close + n);
        }
        if (!bounds.decisive) return .need_more;
        return literal(source, base, offset, s, end);
    }
    return consume(source, base, offset, s);
}

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

test "whitelist syntax preserves lines and links" {
    try expectScan("# Title\n\n> quote\n- [x] item\n1. **bold** _italic_ ~~gone~~ [site](https://x)\n", "Title\n\n> quote\n- [x] item\n1. bold italic gone site (https://x)\n");
    const events = try scanTest(std.testing.allocator, "**a *b* c** [z](url)", 1);
    defer std.testing.allocator.free(events);
    try std.testing.expect(events[0].bold);
    try std.testing.expect(events[2].bold and events[2].italic);
    try std.testing.expect(events[6].underline);
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

test "unsupported syntax and tables remain literal" {
    try expectScan("![**alt**](url) `**raw**` <b>*raw*</b> $**x**$ [^a]\n| a | **b** |\n|---|---|\n", "![**alt**](url) `**raw**` <b>*raw*</b> $**x**$ [^a]\n| a | b |\n|---|---|\n");
    try expectScan("\\*literal\\* 中文 👩‍💻\n", "\\*literal\\* 中文 👩‍💻\n");
    try expectScan("**unclosed *not styled\nnext\n", "**unclosed *not styled\nnext\n");
}

test "fences stream literally without a closing block" {
    try expectScan("```zig\n**code** [x](y)\n```\n~~after~~\n~~~\nlong code\n", "```zig\n**code** [x](y)\n```\nafter\n~~~\nlong code\n");
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
    const input = "**abcdef**";
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
