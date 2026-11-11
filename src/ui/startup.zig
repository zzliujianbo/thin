//! Display-only startup metadata. Never supplied to Runtime or the session journal.
const std = @import("std");
const presentation = @import("presentation.zig");
const version = @import("../app/version.zig");

// Use the target time_t; an opaque tm avoids duplicating libc's struct ABI.
// Startup-only: format immediately before any producer starts; do not expose or
// retain localtime's shared buffer. libc honors TZ or the machine's /etc/localtime,
// including date-specific daylight-saving rules. No process TZ mutation here.
const Tm = opaque {};
extern "c" fn localtime(timer: *const std.c.time_t) ?*const Tm;
extern "c" fn strftime(buffer: [*]u8, length: usize, format: [*:0]const u8, time: *const Tm) usize;

pub fn banner(a: std.mem.Allocator, directory: []const u8, seconds: i64) ![]const u8 {
    const safe = try presentation.singleLine(a, directory, 4096);
    defer a.free(safe);
    var time: [64]u8 = undefined;
    const stamp = if (seconds < 0 or seconds > 253402300799) "unavailable" else blk: {
        const native_seconds = std.math.cast(std.c.time_t, seconds) orelse break :blk "unavailable";
        const local = localtime(&native_seconds) orelse break :blk "unavailable";
        const length = strftime(&time, time.len, "%Y-%m-%d %H:%M:%S %z", local);
        if (length == 0) break :blk "unavailable";
        break :blk time[0..length];
    };
    return std.fmt.allocPrint(a, "{s}\n{s}\n{s}", .{ version.text, safe, stamp });
}
