//! Allocation-free incremental display sanitizer. Emitted slices are borrowed
//! only for the duration of the callback; the recipient must copy them.
const std = @import("std");
const display = @import("display_text.zig");

pub const Decoder = struct {
    carry: [4]u8 = undefined,
    carry_len: usize = 0,
    held_cr: bool = false,

    // On callback failure the decoder and recipient may both be partially
    // advanced. For transactional use, clone the decoder and stage emitted
    // bytes separately, publishing both only after success. The caller retains
    // ownership of raw bytes throughout, including on failure.
    pub fn feed(self: *Decoder, raw: []const u8, context: anytype, comptime emit: anytype) !void {
        var i: usize = 0;
        if (self.held_cr and raw.len != 0) {
            self.held_cr = false;
            if (raw[0] == '\n') {
                try emit(context, "\n");
                i = 1;
            } else try emit(context, "\xef\xbf\xbd");
        }
        if (self.carry_len != 0) {
            const need: usize = std.unicode.utf8ByteSequenceLength(self.carry[0]) catch unreachable;
            while (self.carry_len < need and i < raw.len and raw[i] & 0xc0 == 0x80) : (i += 1) {
                self.carry[self.carry_len] = raw[i];
                self.carry_len += 1;
            }
            if (self.carry_len < need and i == raw.len) return;
            const n = self.carry_len;
            if (n == need) {
                const r = display.decode(self.carry[0..n], 0);
                if (r.end == n) {
                    self.carry_len = 0;
                    try emitScalar(context, emit, r.cp);
                } else {
                    self.carry_len = 0;
                    for (0..n) |_| try emit(context, "\xef\xbf\xbd");
                }
            } else {
                self.carry_len = 0;
                for (0..n) |_| try emit(context, "\xef\xbf\xbd");
            }
        }
        while (i < raw.len) {
            if (raw[i] == '\r') {
                if (i + 1 == raw.len) {
                    self.held_cr = true;
                    return;
                }
                if (raw[i + 1] == '\n') {
                    try emit(context, "\n");
                    i += 2;
                } else {
                    try emit(context, "\xef\xbf\xbd");
                    i += 1;
                }
                continue;
            }
            const need: usize = std.unicode.utf8ByteSequenceLength(raw[i]) catch 0;
            if (need > raw.len - i) {
                var valid_prefix = true;
                for (raw[i + 1 ..]) |b| if (b & 0xc0 != 0x80) {
                    valid_prefix = false;
                    break;
                };
                if (valid_prefix) {
                    self.carry_len = raw.len - i;
                    @memcpy(self.carry[0..self.carry_len], raw[i..]);
                    return;
                }
            }
            const r = display.decode(raw, i);
            try emitScalar(context, emit, r.cp);
            i = r.end;
        }
    }

    /// Flush the current prefix. Clone first for a non-consuming preview.
    /// Failure has the same partial-progress contract as feed.
    pub fn finish(self: *Decoder, context: anytype, comptime emit: anytype) !void {
        if (self.held_cr) {
            self.held_cr = false;
            try emit(context, "\xef\xbf\xbd");
        }
        const n = self.carry_len;
        self.carry_len = 0;
        for (0..n) |_| try emit(context, "\xef\xbf\xbd");
    }
};

fn emitScalar(context: anytype, comptime emit: anytype, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(display.displayCodepoint(cp), &buf) catch unreachable;
    try emit(context, buf[0..n]);
}

const TestSink = struct {
    bytes: std.ArrayList(u8) = .empty,
    fail: bool = false,
    fn emit(self: *TestSink, safe: []const u8) !void {
        if (self.fail) return error.TestFailure;
        try self.bytes.appendSlice(std.testing.allocator, safe);
    }
    fn deinit(self: *TestSink) void {
        self.bytes.deinit(std.testing.allocator);
    }
};

test "all cuts match shared sanitizer, including invalid and controls" {
    const a = std.testing.allocator;
    const input = "xé中文👩‍💻\r\n\rZ\x1b\x18\x7f\xe2\x82A\xf0\x80\x80\x80\xff\t";
    const expected = try display.sanitize(a, input, 4096);
    defer a.free(expected);
    for (0..input.len + 1) |cut| {
        var d: Decoder = .{};
        var sink: TestSink = .{};
        defer sink.deinit();
        try d.feed(input[0..cut], &sink, TestSink.emit);
        try d.feed(input[cut..], &sink, TestSink.emit);
        try d.finish(&sink, TestSink.emit);
        try std.testing.expectEqualStrings(expected, sink.bytes.items);
    }
    var d: Decoder = .{};
    var sink: TestSink = .{};
    defer sink.deinit();
    for (input) |*b| try d.feed(b[0..1], &sink, TestSink.emit);
    try d.finish(&sink, TestSink.emit);
    try std.testing.expectEqualStrings(expected, sink.bytes.items);
}

test "finish clone previews without consuming CR or incomplete UTF8" {
    var d: Decoder = .{};
    var live: TestSink = .{};
    defer live.deinit();
    try d.feed("\r", &live, TestSink.emit);
    var preview = d;
    var p: TestSink = .{};
    defer p.deinit();
    try preview.finish(&p, TestSink.emit);
    try std.testing.expectEqualStrings("�", p.bytes.items);
    try d.feed("\n\xf0\x9f", &live, TestSink.emit);
    preview = d;
    p.bytes.clearRetainingCapacity();
    try preview.finish(&p, TestSink.emit);
    try std.testing.expectEqualStrings("��", p.bytes.items);
    try d.feed("\x98\x80", &live, TestSink.emit);
    try std.testing.expectEqualStrings("\n😀", live.bytes.items);
}

test "failed emit requires clone and staged output; raw remains caller owned" {
    var d: Decoder = .{};
    var sink: TestSink = .{};
    defer sink.deinit();
    try d.feed("\xf0\x9f", &sink, TestSink.emit);
    var trial = d;
    sink.fail = true;
    const raw = "\x98\x80";
    try std.testing.expectError(error.TestFailure, trial.feed(raw, &sink, TestSink.emit));
    try std.testing.expectEqual(@as(usize, 2), d.carry_len);
    sink.fail = false;
    trial = d;
    try trial.feed(raw, &sink, TestSink.emit);
    d = trial;
    try std.testing.expectEqualStrings("😀", sink.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), d.carry_len);
}
