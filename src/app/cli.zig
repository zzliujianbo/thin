//! Parse launch syntax without reading configuration, environment, or session state.
const std = @import("std");
const ids = @import("session_id.zig");

pub const usage = "Usage: thin [--daemon]\n";

pub const Mode = enum {
    foreground,
    daemon,
    worker,

    pub fn requiresTty(self: Mode) bool {
        return switch (self) {
            .foreground => true,
            .daemon, .worker => false,
        };
    }
};

pub const WorkerOwner = enum { foreground, daemon };

pub const Options = struct {
    mode: Mode = .foreground,
    auto_refresh_models: bool = true,
    // Private worker launch data. The child validates its owner before serving.
    worker_endpoint: ?[]const u8 = null,
    worker_session: ?ids.Id = null,
    worker_owner: WorkerOwner = .daemon,
    worker_resume: bool = false,
    worker_restore_selection: ?ids.Id = null,
};

/// Public forms are exactly `thin` and `thin --daemon`. Self-exec accepts only
/// the worker layouts emitted by daemon/spawn.zig.
pub fn parse(args: []const [:0]const u8) !Options {
    if (args.len == 0) return error.InvalidArguments;
    if (args.len == 1) return .{};
    if (args.len == 2 and std.mem.eql(u8, args[1], "--daemon")) return .{ .mode = .daemon };

    if (!std.mem.eql(u8, args[1], "--internal-worker")) return error.InvalidArguments;
    var child = args[2..];
    const no_refresh = child.len != 0 and std.mem.eql(u8, child[child.len - 1], "--no-model-auto-refresh");
    if (no_refresh) child = child[0 .. child.len - 1];

    if (child.len < 3 or !std.fs.path.isAbsolute(child[0])) return error.InvalidArguments;
    var options: Options = .{
        .mode = .worker,
        .worker_endpoint = child[0],
        .worker_session = try parseId(child[1]),
        .worker_owner = std.meta.stringToEnum(WorkerOwner, child[2]) orelse return error.InvalidArguments,
        .auto_refresh_models = !no_refresh,
    };
    const tail = child[3..];
    if (tail.len == 0) return options;
    if (tail.len == 1 and std.mem.eql(u8, tail[0], "--worker-resume")) {
        options.worker_resume = true;
    } else if (tail.len == 2 and std.mem.eql(u8, tail[0], "--worker-restore-selection")) {
        options.worker_restore_selection = try parseId(tail[1]);
    } else return error.InvalidArguments;
    return options;
}

fn parseId(value: []const u8) !ids.Id {
    if (value.len != 32) return error.InvalidSessionID;
    const id: ids.Id = value[0..32].*;
    if (!ids.valid(id)) return error.InvalidSessionID;
    return id;
}
