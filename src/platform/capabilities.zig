//! Product capabilities, checked after syntax and before configuration, listeners or workers.
const builtin = @import("builtin");
const cli = @import("../app/cli.zig");

pub const local_only = builtin.os.tag == .macos;
pub const daemon = builtin.os.tag == .linux;

pub fn validate(options: cli.Options) !void {
    if (!local_only) return;
    switch (options.mode) {
        .daemon => return error.UnsupportedPlatformMode,
        .worker => if (options.worker_owner != .foreground) return error.UnsupportedPlatformMode,
        .foreground => {},
    }
}
