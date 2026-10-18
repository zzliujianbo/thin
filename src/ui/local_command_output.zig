//! Display-only bash result projection. Never decodes shell \xHH escapes or
//! treats output as Markdown/terminal instructions; canonical bytes are untouched.
const std = @import("std");
const clean = @import("../util/display_text.zig");
pub const limit = 128 * 1024;
pub const Output = struct { text: []const u8, clipped: bool };
const Bash = struct {
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    exit_code: ?i64 = null,
    signal: ?i64 = null,
    timed_out: ?bool = null,
    canceled: ?bool = null,
    cleanup_failed: ?bool = null,
    truncated: ?bool = null,
    output_encoding: ?[]const u8 = null,
};

// Accept only a flat object. This lexical guard bounds scanner/parser recursion
// even for ignored unknown fields. JSON validity is still checked by std.json.
fn flat(input: []const u8) bool {
    const s = std.mem.trim(u8, input, " \r\n\t");
    if (s.len < 2 or s[0] != '{' or s[s.len - 1] != '}') return false;
    var quoted = false;
    var escaped = false;
    for (s[1 .. s.len - 1]) |c| {
        if (quoted) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') quoted = false;
        } else if (c == '"') {
            quoted = true;
        } else if (c == '{' or c == '}' or c == '[' or c == ']') return false;
    }
    return !quoted;
}

const Buffer = struct {
    a: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    clipped: bool = false,
    fn put(self: *Buffer, s: []const u8) !void {
        var n = @min(s.len, limit - self.bytes.items.len);
        while (n > 0 and n < s.len and s[n] & 0xc0 == 0x80) n -= 1;
        try self.bytes.appendSlice(self.a, s[0..n]);
        self.clipped = self.clipped or n != s.len;
    }
    fn field(self: *Buffer, label: []const u8, s: []const u8) !void {
        try self.put(label);
        try self.put(s);
        try self.put("\n");
    }
};

pub fn format(a: std.mem.Allocator, input: []const u8) !Output {
    if (input.len > limit or !flat(input)) return literal(a, input);
    // Explicit allocation bound independent of JSON token count; no arbitrary
    // Value tree. Genuine allocation failure propagates rather than hiding OOM.
    const scratch = try a.alloc(u8, input.len * 8 + 4096);
    defer a.free(scratch);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const parsed = std.json.parseFromSlice(Bash, fixed.allocator(), input, .{ .ignore_unknown_fields = true, .max_value_len = limit }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return literal(a, input),
    };
    defer parsed.deinit();
    const v = parsed.value;
    // Unrelated JSON isn't evidence of a bash result.
    if (v.stdout == null and v.stderr == null and v.exit_code == null and v.signal == null and v.timed_out == null and v.canceled == null and v.cleanup_failed == null and v.truncated == null and v.output_encoding == null) return literal(a, input);
    var b = Buffer{ .a = a };
    defer b.bytes.deinit(a);
    if (v.stdout) |s| try b.field("stdout:\n", s);
    if (v.stderr) |s| try b.field("stderr:\n", s);
    var number: [32]u8 = undefined;
    if (v.exit_code) |code| try b.field("exit: ", try std.fmt.bufPrint(&number, "{d}", .{code})) else try b.put("exit: unknown\n");
    if (v.signal) |signal| try b.field("signal: ", try std.fmt.bufPrint(&number, "{d}", .{signal}));
    if (v.timed_out == true) try b.put("timed out\n");
    if (v.canceled == true) try b.put("canceled\n");
    if (v.cleanup_failed == true) try b.put("cleanup failed\n");
    if (v.truncated == true) try b.put("output truncated\n");
    if (v.output_encoding) |s| try b.field("output encoding: ", s);
    const safe = try clean.sanitizePrefix(a, b.bytes.items, limit);
    return .{ .text = safe.text, .clipped = b.clipped or safe.truncated };
}

fn literal(a: std.mem.Allocator, input: []const u8) !Output {
    // Bound even malformed/oversized fallback work, preserving it as literal
    // text (not a claimed execution status).
    const safe = try clean.sanitizePrefix(a, input[0..@min(input.len, limit)], limit);
    return .{ .text = safe.text, .clipped = safe.truncated or input.len > limit };
}

test "local output streams statuses and unsafe text are literal" {
    const a = std.testing.allocator;
    const out = try format(a, "{\"stdout\":\"**literal**\\n\\u001b[2J\\\\x1b\",\"stderr\":\"bad\",\"exit_code\":7,\"signal\":9,\"timed_out\":true,\"canceled\":true,\"cleanup_failed\":true,\"truncated\":true,\"output_encoding\":\"utf8\"}");
    defer a.free(out.text);
    for ([_][]const u8{ "stdout:\n**literal**", "stderr:\nbad", "exit: 7", "signal: 9", "timed out", "canceled", "cleanup failed", "output truncated", "output encoding: utf8", "\\x1b" }) |s| try std.testing.expect(std.mem.indexOf(u8, out.text, s) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.text, 0x1b) == null);
}

test "local output fallback empty unknown and bounded" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "Denied", "", "{}", "{\"unknown\":{\"nested\":[]}}", "{\"stdout\":42}" }) |s| {
        const out = try format(a, s);
        defer a.free(out.text);
        try std.testing.expectEqualStrings(s, out.text);
    }
    const empty = try format(a, "{\"stdout\":\"\",\"truncated\":true}");
    defer a.free(empty.text);
    try std.testing.expectEqualStrings("stdout:\n\nexit: unknown\noutput truncated\n", empty.text);
    const large = try a.alloc(u8, limit + 1);
    defer a.free(large);
    @memset(large, 'x');
    const out = try format(a, large);
    defer a.free(out.text);
    try std.testing.expect(out.clipped and out.text.len <= limit);
}

test "local output propagates allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            const out = try format(a, "{\"stdout\":\"hello\\nworld\",\"exit_code\":7}");
            defer a.free(out.text);
        }
    }.run, .{});
}
