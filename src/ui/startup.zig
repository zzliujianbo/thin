//! Display-only startup metadata. Never supplied to Runtime or the session journal.
const std = @import("std");
const presentation = @import("presentation.zig");
const version = @import("../app/version.zig");

// Linux x86_64 time_t is i64. An opaque tm avoids duplicating libc's struct ABI.
// Startup-only: format immediately before any producer starts; do not expose or
// retain localtime's shared buffer. libc honors TZ or the machine's /etc/localtime,
// including date-specific daylight-saving rules. No process TZ mutation here.
const Tm = opaque {};
extern "c" fn localtime(timer: *const i64) ?*const Tm;
extern "c" fn strftime(buffer: [*]u8, length: usize, format: [*:0]const u8, time: *const Tm) usize;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub fn banner(a: std.mem.Allocator, directory: []const u8, seconds: i64) ![]const u8 {
    const safe = try presentation.singleLine(a, directory, 4096);
    defer a.free(safe);
    var time: [64]u8 = undefined;
    const stamp = if (seconds < 0 or seconds > 253402300799) "unavailable" else blk: {
        const local = localtime(&seconds) orelse break :blk "unavailable";
        const length = strftime(&time, time.len, "%Y-%m-%d %H:%M:%S %z", local);
        if (length == 0) break :blk "unavailable";
        break :blk time[0..length];
    };
    return std.fmt.allocPrint(a, "{s}\n{s}\n{s}", .{ version.text, safe, stamp });
}

test "startup shows Thin version safe directory and local timezone offset" {
    const a = std.testing.allocator;
    try @import("text.zig").initLocale();
    const value = try banner(a, "/tmp/project\nspoof\t\x1b[31m", 0);
    defer a.free(value);
    try std.testing.expect(std.mem.startsWith(u8, value, version.text ++ "\n/tmp/project spoof "));
    try std.testing.expect(std.mem.find(u8, value, "Directory: ") == null);
    try std.testing.expect(std.mem.find(u8, value, "Time: ") == null);
    try std.testing.expect(value[value.len - 5] == '+' or value[value.len - 5] == '-');
    for (value[value.len - 4 ..]) |digit| try std.testing.expect(digit >= '0' and digit <= '9');
    try std.testing.expect(std.mem.findScalar(u8, value, 0x1b) == null);
    try std.testing.expect(std.mem.find(u8, value, "Zig") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, value, "\n"));
    // Focused runs supply these POSIX TZ values externally; never mutate the
    // process-wide timezone while I/O threads may exist.
    if (getenv("TZ")) |zone| {
        if (std.mem.eql(u8, std.mem.span(zone), "UTC0"))
            try std.testing.expect(std.mem.endsWith(u8, value, "1970-01-01 00:00:00 +0000"));
        if (std.mem.eql(u8, std.mem.span(zone), "UTC-8"))
            try std.testing.expect(std.mem.endsWith(u8, value, "1970-01-01 08:00:00 +0800"));
    }
    const unavailable = try banner(a, "/project", -1);
    defer a.free(unavailable);
    try std.testing.expect(std.mem.eql(u8, unavailable, version.text ++ "\n/project\nunavailable"));
}
