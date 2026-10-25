//! Unified runtime entry. `main` keeps help/version, `--print`, the TTY gate and
//! locale setup; this module only routes the remaining explicit modes.
//!
//! Signal-guard ownership: the worker installs its own guard (it must install
//! parent-death handling between two guard checks), the daemon installs its own,
//! and interactive client modes are guarded here exactly once.

const std = @import("std");
const cli = @import("../app/cli.zig");
const interrupt = @import("../platform/interrupt.zig");
const worker = @import("worker.zig");
const client = @import("client.zig");
const supervisor = @import("supervisor.zig");

pub fn run(init: std.process.Init, options: cli.Options) !u8 {
    return switch (options.mode) {
        // Explicit service mode only; ordinary foreground never starts a daemon.
        .daemon => supervisor.run(init, options),
        .worker => worker.run(init, options),
        .foreground, .connect, .attach => blk: {
            var guard = try interrupt.Guard.install();
            defer guard.deinit();
            break :blk client.run(init, options);
        },
    };
}
