//! Allocation-free, preview-only incremental JSON validator. Never use previews
//! as execution arguments. Slices borrow the extractor; snapshot again after a move.
const std = @import("std");

pub const Field = struct { text: []const u8, truncated: bool = false };
pub const Snapshot = struct { path: ?Field = null, command: ?Field = null, action: ?Field = null, topic: ?Field = null };

const capacity = 1024;
const max_depth = 32;
const names = [_][]const u8{ "path", "command", "action", "topic" };
const Phase = enum { object_first, object_key, colon, value, object_after, array_first, array_value, array_after };
const Mode = enum { syntax, string, number, literal };
const Escape = enum { normal, escaped, unicode, low_slash, low_u };
const Number = enum { minus, zero, integer, dot, fraction, exponent, exponent_sign, exponent_digits };

pub const Extractor = struct {
    buffers: [4][capacity]u8 = undefined,
    lengths: [4]usize = @splat(0),
    truncated: [4]bool = @splat(false),
    present: [4]bool = @splat(false),
    seen: [4]bool = @splat(false),
    stack: [max_depth]Phase = undefined,
    depth: usize = 0,
    started: bool = false,
    done: bool = false,
    invalid: bool = false,
    mode: Mode = .syntax,
    selected: ?usize = null,
    string_key: bool = false,
    key: [7]u8 = undefined,
    key_len: usize = 0,
    key_overflow: bool = false,
    escape: Escape = .normal,
    hex_digits: u3 = 0,
    hex_value: u21 = 0,
    high_surrogate: ?u21 = null,
    utf_remaining: u3 = 0,
    utf_value: u21 = 0,
    utf_min: u21 = 0,
    number: Number = .zero,
    literal: []const u8 = "",
    literal_pos: usize = 0,

    pub fn feed(self: *Extractor, chunk: []const u8) void {
        for (chunk) |byte| {
            if (self.invalid) return;
            self.consume(byte);
        }
    }

    pub fn snapshot(self: *const Extractor) Snapshot {
        if (self.invalid) return .{};
        var result: Snapshot = .{};
        inline for (.{ "path", "command", "action", "topic" }, 0..) |name, i| {
            if (self.present[i]) @field(result, name) = .{ .text = self.buffers[i][0..self.lengths[i]], .truncated = self.truncated[i] };
        }
        return result;
    }

    pub fn finish(self: *Extractor) bool {
        if (!self.done or self.mode != .syntax or self.depth != 0) self.invalid = true;
        return !self.invalid;
    }

    fn whitespace(b: u8) bool {
        return b == ' ' or b == '\t' or b == '\r' or b == '\n';
    }

    fn consume(self: *Extractor, b: u8) void {
        switch (self.mode) {
            .string => return self.stringByte(b),
            .literal => {
                if (b != self.literal[self.literal_pos]) {
                    self.invalid = true;
                    return;
                }
                self.literal_pos += 1;
                if (self.literal_pos == self.literal.len) {
                    self.mode = .syntax;
                    self.valueDone();
                }
                return;
            },
            .number => {
                if (self.numberByte(b)) return;
                if (self.invalid) return;
                self.mode = .syntax;
                self.valueDone();
                // A delimiter terminates the number and is consumed as syntax.
            },
            .syntax => {},
        }
        if (whitespace(b)) return;
        if (self.done) {
            self.invalid = true;
            return;
        }
        if (!self.started) {
            if (b != '{') {
                self.invalid = true;
                return;
            }
            self.started = true;
            self.push(.object_first);
            return;
        }
        switch (self.stack[self.depth - 1]) {
            .object_first, .object_key => |phase| {
                if (b == '}' and phase == .object_first) return self.close();
                if (b != '"') {
                    self.invalid = true;
                    return;
                }
                self.beginString(true);
            },
            .colon => {
                if (b != ':') self.invalid = true else self.stack[self.depth - 1] = .value;
            },
            .value, .array_first, .array_value => |phase| {
                if (b == ']' and phase == .array_first) return self.close();
                if (self.depth == 1 and self.selected != null and b != '"') {
                    self.invalid = true;
                    return;
                }
                switch (b) {
                    '"' => self.beginString(false),
                    '{' => self.push(.object_first),
                    '[' => self.push(.array_first),
                    't', 'f', 'n' => {
                        self.literal = switch (b) {
                            't' => "true",
                            'f' => "false",
                            else => "null",
                        };
                        self.literal_pos = 1;
                        self.mode = .literal;
                    },
                    '-', '0'...'9' => {
                        self.mode = .number;
                        self.number = if (b == '-') .minus else if (b == '0') .zero else .integer;
                    },
                    else => self.invalid = true,
                }
            },
            .object_after => {
                if (b == '}') self.close() else if (b == ',') self.stack[self.depth - 1] = .object_key else self.invalid = true;
            },
            .array_after => {
                if (b == ']') self.close() else if (b == ',') self.stack[self.depth - 1] = .array_value else self.invalid = true;
            },
        }
    }

    fn push(self: *Extractor, phase: Phase) void {
        if (self.depth == max_depth) {
            self.invalid = true;
            return;
        }
        self.stack[self.depth] = phase;
        self.depth += 1;
    }

    fn close(self: *Extractor) void {
        self.depth -= 1;
        if (self.depth == 0) self.done = true else self.valueDone();
    }

    fn valueDone(self: *Extractor) void {
        self.stack[self.depth - 1] = switch (self.stack[self.depth - 1]) {
            .value => .object_after,
            .array_first, .array_value => .array_after,
            else => unreachable,
        };
        if (self.depth == 1) self.selected = null;
    }

    fn beginString(self: *Extractor, key: bool) void {
        self.mode = .string;
        self.string_key = key;
        self.key_len = 0;
        self.key_overflow = false;
        self.escape = .normal;
        self.high_surrogate = null;
        self.utf_remaining = 0;
    }

    // Accept only whole decoded scalars. Once full, never append later scalars:
    // retained data must be a prefix, not a sequence with omitted middle bytes.
    fn scalar(self: *Extractor, cp: u21) void {
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &bytes) catch {
            self.invalid = true;
            return;
        };
        if (self.string_key) {
            if (self.depth != 1 or self.key_overflow) return;
            if (self.key_len + len > self.key.len) {
                self.key_overflow = true;
                return;
            }
            @memcpy(self.key[self.key_len..][0..len], bytes[0..len]);
            self.key_len += len;
        } else if (self.depth == 1) {
            if (self.selected) |i| {
                if (self.truncated[i]) return;
                if (self.lengths[i] + len > capacity) {
                    self.truncated[i] = true;
                    return;
                }
                @memcpy(self.buffers[i][self.lengths[i]..][0..len], bytes[0..len]);
                self.lengths[i] += len;
            }
        }
    }

    fn stringByte(self: *Extractor, b: u8) void {
        if (self.utf_remaining != 0) {
            if (b < 0x80 or b > 0xbf) {
                self.invalid = true;
                return;
            }
            self.utf_value = (self.utf_value << 6) | @as(u21, b & 0x3f);
            self.utf_remaining -= 1;
            if (self.utf_remaining == 0) {
                const cp = self.utf_value;
                if (cp < self.utf_min or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) self.invalid = true else self.scalar(cp);
            }
            return;
        }
        switch (self.escape) {
            .low_slash => {
                if (b != '\\') self.invalid = true else self.escape = .low_u;
            },
            .low_u => {
                if (b != 'u') self.invalid = true else self.startHex();
            },
            .unicode => {
                const digit: u21 = switch (b) {
                    '0'...'9' => b - '0',
                    'a'...'f' => b - 'a' + 10,
                    'A'...'F' => b - 'A' + 10,
                    else => {
                        self.invalid = true;
                        return;
                    },
                };
                self.hex_value = (self.hex_value << 4) | digit;
                self.hex_digits += 1;
                if (self.hex_digits == 4) {
                    const cp = self.hex_value;
                    if (self.high_surrogate) |high| {
                        if (cp < 0xdc00 or cp > 0xdfff) {
                            self.invalid = true;
                            return;
                        }
                        self.scalar(0x10000 + ((high - 0xd800) << 10) + cp - 0xdc00);
                        self.high_surrogate = null;
                        self.escape = .normal;
                    } else if (cp >= 0xd800 and cp <= 0xdbff) {
                        self.high_surrogate = cp;
                        self.escape = .low_slash;
                    } else if (cp >= 0xdc00 and cp <= 0xdfff) {
                        self.invalid = true;
                    } else {
                        self.scalar(cp);
                        self.escape = .normal;
                    }
                }
            },
            .escaped => {
                self.escape = .normal;
                switch (b) {
                    '"', '\\', '/' => self.scalar(b),
                    'b' => self.scalar(8),
                    'f' => self.scalar(12),
                    'n' => self.scalar(10),
                    'r' => self.scalar(13),
                    't' => self.scalar(9),
                    'u' => self.startHex(),
                    else => self.invalid = true,
                }
            },
            .normal => switch (b) {
                '"' => self.endString(),
                '\\' => self.escape = .escaped,
                0...0x1f => self.invalid = true,
                0x20...0x21, 0x23...0x5b, 0x5d...0x7f => self.scalar(b),
                0xc2...0xdf => self.startUtf(b & 0x1f, 1, 0x80),
                0xe0...0xef => self.startUtf(b & 0x0f, 2, 0x800),
                0xf0...0xf4 => self.startUtf(b & 7, 3, 0x10000),
                else => self.invalid = true,
            },
        }
    }

    fn startHex(self: *Extractor) void {
        self.escape = .unicode;
        self.hex_digits = 0;
        self.hex_value = 0;
    }

    fn startUtf(self: *Extractor, value: u21, remaining: u3, minimum: u21) void {
        self.utf_value = value;
        self.utf_remaining = remaining;
        self.utf_min = minimum;
    }

    fn endString(self: *Extractor) void {
        self.mode = .syntax;
        if (self.string_key) {
            self.stack[self.depth - 1] = .colon;
            if (self.depth != 1) return;
            self.selected = null;
            if (!self.key_overflow) {
                for (names, 0..) |name, i| {
                    if (std.mem.eql(u8, name, self.key[0..self.key_len])) {
                        if (self.seen[i]) self.invalid = true;
                        self.seen[i] = true;
                        self.selected = i;
                        break;
                    }
                }
            }
        } else {
            if (self.depth == 1) {
                if (self.selected) |i| self.present[i] = true;
            }
            self.valueDone();
        }
    }

    fn numberByte(self: *Extractor, b: u8) bool {
        const digit = b >= '0' and b <= '9';
        switch (self.number) {
            .minus => {
                if (!digit) self.invalid = true else self.number = if (b == '0') .zero else .integer;
            },
            .zero, .integer => {
                if (digit and self.number == .integer) return true;
                if (b == '.') self.number = .dot else if (b == 'e' or b == 'E') self.number = .exponent else return false;
            },
            .dot => {
                if (!digit) self.invalid = true else self.number = .fraction;
            },
            .fraction => {
                if (digit) return true;
                if (b == 'e' or b == 'E') self.number = .exponent else return false;
            },
            .exponent => {
                if (b == '+' or b == '-') self.number = .exponent_sign else if (digit) self.number = .exponent_digits else self.invalid = true;
            },
            .exponent_sign => {
                if (digit) self.number = .exponent_digits else self.invalid = true;
            },
            .exponent_digits => if (!digit) return false,
        }
        return true;
    }
};

fn expectEmpty(e: *const Extractor) !void {
    const s = e.snapshot();
    try std.testing.expect(s.path == null and s.command == null and s.action == null and s.topic == null);
}

fn checkGolden(e: *const Extractor) !void {
    const s = e.snapshot();
    try std.testing.expectEqualStrings("目录/😀/\\\"\n", s.path.?.text);
    try std.testing.expectEqualStrings("echo hi", s.command.?.text);
    try std.testing.expectEqualStrings("", s.action.?.text);
    try std.testing.expectEqualStrings("中", s.topic.?.text);
    try std.testing.expect(!s.path.?.truncated);
}

test "all two-chunk splits and byte-by-byte decoded keys scalars nested values" {
    const json = "{\"pa\\u0074h\":\"目录/\\uD83D\\uDE00/\\\\\\\"\\n\",\"content\":\"fake \\\"path\\\":\\\"evil\\\"\",\"other\":[{\"path\":42},true,false,null,-1.25e+3,0],\"command\":\"echo hi\",\"action\":\"\",\"topic\":\"中\"} \r\n";
    for (0..json.len + 1) |split| {
        var e: Extractor = .{};
        e.feed(json[0..split]);
        e.feed(json[split..]);
        try std.testing.expect(e.finish());
        try checkGolden(&e);
    }
    var e: Extractor = .{};
    for (json) |b| e.feed(&.{b});
    try std.testing.expect(e.finish());
    try checkGolden(&e);
}

test "unknown content and nested names never publish and long keys do not alias" {
    const json = "{\"content\":\"\\\"path\\\":\\\"fake\\\"\",\"expected_version\":\"path\",\"nested\":[{\"path\":\"wrong\",\"command\":\"wrong\"}],\"pathTOOLONG\":\"wrong\",\"commandx\":\"wrong\",\"unknown\":[0,-0,10,-10,1.2,1E2,1e-2,true,false,null,{},[]]}";
    for (0..json.len + 1) |split| {
        var e: Extractor = .{};
        e.feed(json[0..split]);
        e.feed(json[split..]);
        try std.testing.expect(e.finish());
        try expectEmpty(&e);
    }
    var escaped: Extractor = .{};
    const keys = " \t{\"co\\u006dmand\":\"\\b\\f\\n\\r\\t\\/\\u0000\",\"\\u0061ction\":\"😀\",\"to\\u0070ic\":\"\\u4e2d\"}";
    for (keys) |b| escaped.feed(&.{b});
    try std.testing.expect(escaped.finish());
    try std.testing.expectEqualStrings("\x08\x0c\n\r\t/\x00", escaped.snapshot().command.?.text);
    try std.testing.expectEqualStrings("😀", escaped.snapshot().action.?.text);
    try std.testing.expectEqualStrings("中", escaped.snapshot().topic.?.text);
}

test "closed path available during 100KiB content without storing it" {
    var e: Extractor = .{};
    e.feed("{\"path\":\"safe\",\"content\":\"");
    try std.testing.expectEqualStrings("safe", e.snapshot().path.?.text);
    const block: [1024]u8 = @splat('x');
    for (0..100) |_| e.feed(&block);
    e.feed("\\\"path\\\":\\\"evil\\\"\",\"expected_version\":123,\"nested\":{\"path\":\"wrong\"}}");
    try std.testing.expect(e.finish());
    try std.testing.expectEqualStrings("safe", e.snapshot().path.?.text);
    try std.testing.expectEqual(@as(usize, 4), e.lengths[0]);
    try std.testing.expectEqual(@as(usize, 4096), @sizeOf(@TypeOf(e.buffers)));
}

test "strict invalid cases revoke all fields at every split and stay invalid" {
    const cases = [_][]const u8{
        "[]",                                   "null",                                       "{\"path\":1}",                 "{\"path\":null}",               "{\"path\":{}}",       "{\"path\":[]}",
        "{\"path\":\"ok\",\"path\":\"again\"}", "{\"path\":\"ok\",\"pa\\u0074h\":\"again\"}", "{\"path\":\"ok\"}x",           "{\"path\":\"ok\"}{}",           "{\"path\":\"ok\",}",  "{\"path\":\"ok\",\"x\":[1,]}",
        "{\"path\":\"ok\",\"x\":01}",           "{\"x\":-}",                                  "{\"x\":1.}",                   "{\"x\":1e}",                    "{\"x\":1e+}",         "{\"x\":tru}",
        "{\"x\":truefalse}",                    "{\"x\":NaN}",                                "{\"x\":+1}",                   "{\"x\":1 2}",                   "{\"x\":[}}",          "{\"path\":\"ok\",\"content\":\"\\q\"}",
        "{\"path\":\"\\uDC00\"}",               "{\"path\":\"\\uD800x\"}",                    "{\"path\":\"\\uD800\\n\"}",    "{\"path\":\"\\uD800\\u0041\"}", "{\"x\":\"\\uZZZZ\"}", "{\"x\":\"\n\"}",
        "{\"x\":\"\xc0\xaf\"}",                 "{\"x\":\"\xed\xa0\x80\"}",                   "{\"x\":\"\xf4\x90\x80\x80\"}", "{\"x\":\"\xe0\x80\x80\"}",      "{\"x\":\"\x80\"}",    "{\"x\":\"\xc2x\"}",
        "{\"\xff\":0}",                         "{\"x\":\"\xf5\x80\x80\x80\"}",
    };
    for (cases) |json| {
        for (0..json.len + 1) |split| {
            var e: Extractor = .{};
            e.feed(json[0..split]);
            e.feed(json[split..]);
            try std.testing.expect(!e.finish());
            try expectEmpty(&e);
            e.feed("{}");
            try std.testing.expect(!e.finish());
            try expectEmpty(&e);
        }
        var e: Extractor = .{};
        for (json) |b| e.feed(&.{b});
        try std.testing.expect(!e.finish());
        try expectEmpty(&e);
    }
}

test "unfinished input is not invalid until finish and no unclosed value leaks" {
    const json = "{\"path\":\"safe\",\"topic\":\"中\\uD83D\\uDE00\"}";
    for (0..json.len) |end| {
        var e: Extractor = .{};
        e.feed(json[0..end]);
        try std.testing.expect(!e.invalid);
        try std.testing.expect(!e.finish());
        try expectEmpty(&e);
    }
    var e: Extractor = .{};
    e.feed("{\"path\":\"unclosed");
    try expectEmpty(&e);
    e.feed("\"");
    try std.testing.expectEqualStrings("unclosed", e.snapshot().path.?.text);
    e.feed("}");
    try std.testing.expect(e.finish());
    e.feed(" \n\t\r");
    try std.testing.expect(e.finish());
    e.feed("!");
    try expectEmpty(&e);
}

test "bounded depth valid at limit invalid beyond limit" {
    var e: Extractor = .{};
    e.feed("{\"path\":\"ok\",\"x\":");
    for (1..max_depth) |_| e.feed("[");
    e.feed("0");
    for (1..max_depth) |_| e.feed("]");
    e.feed("}");
    try std.testing.expect(e.finish());
    var bad: Extractor = .{};
    bad.feed("{\"path\":\"ok\",\"x\":");
    for (0..max_depth) |_| bad.feed("[");
    try std.testing.expect(bad.invalid);
    try expectEmpty(&bad);
}

test "UTF8 prefix truncation is scalar aligned and validation continues" {
    for (0..4) |room| {
        var e: Extractor = .{};
        e.feed("{\"path\":\"");
        for (0..capacity - room) |_| e.feed("a");
        for ("😀") |b| e.feed(&.{b});
        e.feed("z\",\"command\":\"done\"}");
        try std.testing.expect(e.finish());
        const f = e.snapshot().path.?;
        try std.testing.expect(f.truncated);
        try std.testing.expectEqual(capacity - room, f.text.len);
        try std.testing.expect(std.unicode.utf8ValidateSlice(f.text));
        try std.testing.expectEqualStrings("done", e.snapshot().command.?.text);
    }
    var exact: Extractor = .{};
    exact.feed("{\"path\":\"");
    for (0..capacity / 4) |_| exact.feed("\\uD83D\\uDE00");
    exact.feed("\"}");
    try std.testing.expect(exact.finish());
    try std.testing.expectEqual(capacity, exact.snapshot().path.?.text.len);
    try std.testing.expect(!exact.snapshot().path.?.truncated);
    var bad: Extractor = .{};
    bad.feed("{\"path\":\"");
    for (0..capacity + 1) |_| bad.feed("a");
    bad.feed("\\q\"}");
    try std.testing.expect(!bad.finish());
    try expectEmpty(&bad);
}
