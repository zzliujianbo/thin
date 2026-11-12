//! Display-only bash result projection. Never decodes shell \xHH escapes or
//! treats output as Markdown/terminal instructions; canonical bytes are untouched.
const std = @import("std");
const clean = @import("../util/display_text.zig");
pub const Output = struct { text: []const u8 };
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
    fn put(self: *Buffer, s: []const u8) !void {
        try self.bytes.appendSlice(self.a, s);
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
    if (!flat(input)) return literal(a, input);
    const parsed = std.json.parseFromSlice(Bash, a, input, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
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
    const safe = try clean.sanitizeAll(a, b.bytes.items);
    return .{ .text = safe };
}

fn literal(a: std.mem.Allocator, input: []const u8) !Output {
    // Preserve malformed or unrelated input as literal text, not a status.
    return .{ .text = try clean.sanitizeAll(a, input) };
}
