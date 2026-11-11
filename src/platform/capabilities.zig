//! Product capabilities, checked before configuration, listeners or workers.
const std = @import("std");
const builtin = @import("builtin");

pub const local_only = builtin.os.tag == .macos;
pub const ssh = builtin.os.tag == .linux;
pub const daemon = builtin.os.tag == .linux;

/// Keep CLI grammar portable; reject unsupported modes at the product boundary.
pub fn validate(options: anytype) !void {
    if (!local_only) return;
    if (options.ssh_owner != null or options.ssh_listen != null or options.takeover)
        return error.UnsupportedPlatformMode;
    switch (options.mode) {
        .daemon, .connect, .attach => return error.UnsupportedPlatformMode,
        .worker => if (options.worker_owner != .foreground) return error.UnsupportedPlatformMode,
        .foreground => {},
    }
}

/// Also diagnose incomplete unsupported flags, without interpreting prompt or
/// internal positional arguments as flags. This performs no external I/O.
pub fn validateArgs(args: []const [:0]const u8) !void {
    if (!local_only) return;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        for ([_][]const u8{ "--daemon", "--connect", "--attach", "--takeover", "--ssh-listen", "--internal-ssh" }) |unsupported| {
            if (std.mem.eql(u8, arg, unsupported)) return error.UnsupportedPlatformMode;
        }
        if (std.mem.eql(u8, arg, "--internal-worker")) {
            i += @min(@as(usize, 3), args.len - i - 1);
        } else {
            for ([_][]const u8{ "--print", "-p", "--resume", "--restore-selection", "--worker-restore-selection" }) |takes_value| {
                if (std.mem.eql(u8, arg, takes_value)) {
                    if (i + 1 < args.len) i += 1;
                    break;
                }
            }
        }
    }
}

test "macOS rejects service modes without interpreting prompt data as flags" {
    if (!local_only) return error.SkipZigTest;
    const cli = @import("../app/cli.zig");
    try validateArgs(&.{ "thin", "--print", "--daemon" });
    try validate(try cli.parse(&.{ "thin", "--print", "--daemon" }));
    try validate(try cli.parse(&.{"thin"}));
    for ([_][]const u8{ "--daemon", "--connect", "--attach", "--takeover", "--ssh-listen", "--internal-ssh" }) |flag| {
        const terminated = try std.testing.allocator.dupeSentinel(u8, flag, 0);
        defer std.testing.allocator.free(terminated);
        try std.testing.expectError(error.UnsupportedPlatformMode, validateArgs(&.{ "thin", terminated }));
    }
    try std.testing.expectError(error.UnsupportedPlatformMode, validate(try cli.parse(&.{ "thin", "--daemon" })));
    const id = "0123456789abcdef0123456789abcdef";
    try validate(try cli.parse(&.{ "thin", "--internal-worker", "/tmp/owned.sock", id, "foreground" }));
    try std.testing.expectError(error.UnsupportedPlatformMode, validate(try cli.parse(&.{ "thin", "--internal-worker", "/tmp/owned.sock", id, "daemon" })));
}
