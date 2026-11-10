//! Private Darwin process-query ABI. C owns SDK structs and symbolic flags;
//! Zig owns cancellation, clocks, deadlines, signals and the exact child PID.
const std = @import("std");
const c = std.c;

extern "c" fn thin_darwin_process_observed_exit(pid: c.pid_t) c_int;
extern "c" fn thin_darwin_process_reap(pid: c.pid_t, status: *c_int) c.pid_t;
extern "c" fn thin_darwin_process_group_alive(pgid: c.pid_t, remaining_ms: u32) c_int;

pub fn observedExit(pid: c.pid_t) !bool {
    const rc = thin_darwin_process_observed_exit(pid);
    if (rc >= 0) return rc != 0;
    return switch (std.posix.errno(rc)) {
        .INTR => false,
        .CHILD => error.ChildOwnershipLost,
        else => error.WaitFailed,
    };
}

pub fn reap(pid: c.pid_t, status: *c_int) c.pid_t {
    return thin_darwin_process_reap(pid, status);
}

/// Only call while the owned direct leader remains unreaped. An unavailable,
/// incomplete or racing snapshot is an error, NEVER an empty/dead group.
pub fn groupAlive(pgid: c.pid_t, remaining_ms: u32) !bool {
    const rc = thin_darwin_process_group_alive(pgid, remaining_ms);
    if (rc < 0) return error.ProcUnavailable;
    return rc != 0;
}
