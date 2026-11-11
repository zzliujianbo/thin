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
    fn lineBreak(self: *Buffer) !void {
        if (self.bytes.items.len != 0 and self.bytes.items[self.bytes.items.len - 1] != '\n') try self.put("\n");
    }
    fn stream(self: *Buffer, s: []const u8) !void {
        if (s.len == 0) return;
        try self.lineBreak();
        try self.put(s);
    }
    fn status(self: *Buffer, s: []const u8) !void {
        try self.lineBreak();
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
    // Preserve the canonical JSON envelope for history/replay, but project
    // ordinary terminal output literally: no stdout/stderr headings, success
    // status, byte counts, or encoding implementation details.
    if (v.stdout) |s| try b.stream(s);
    if (v.stderr) |s| try b.stream(s);
    var status_buffer: [64]u8 = undefined;
    if (v.timed_out == true) try b.status("Command timed out");
    if (v.canceled == true) try b.status("Command canceled");
    if (v.signal) |signal| try b.status(try std.fmt.bufPrint(&status_buffer, "Command terminated by signal {d}", .{signal}));
    if (v.exit_code) |code| if (code != 0) try b.status(try std.fmt.bufPrint(&status_buffer, "Command exited with status {d}", .{code}));
    if (v.cleanup_failed == true) try b.status("Command cleanup failed");
    if (v.truncated == true) try b.status("[output truncated]");
    const safe = try clean.sanitizePrefix(a, b.bytes.items, limit);
    return .{ .text = safe.text, .clipped = b.clipped or safe.truncated };
}

fn literal(a: std.mem.Allocator, input: []const u8) !Output {
    // Bound even malformed/oversized fallback work, preserving it as literal
    // text (not a claimed execution status).
    const safe = try clean.sanitizePrefix(a, input[0..@min(input.len, limit)], limit);
    return .{ .text = safe.text, .clipped = safe.truncated or input.len > limit };
}
