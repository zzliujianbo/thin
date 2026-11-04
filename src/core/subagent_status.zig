//! Display-only status for one root's child jobs.
//! Views borrow `agents` unless explicitly cloned; each AgentView owns its text.

const std = @import("std");

pub const Phase = enum { starting, running, waiting, completed, failed, canceled, paused };

pub const AgentView = struct {
    id: u64 = 0,
    revision: u64 = 0,
    phase: Phase = .starting,
    elapsed_ms: u64 = 0,
    text_len: u16 = 0,
    text_buf: [2048]u8 = @splat(0),

    pub fn latestText(self: *const AgentView) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    pub fn active(self: AgentView) bool {
        return self.phase == .starting or self.phase == .running or self.phase == .waiting;
    }
};

pub const View = struct {
    agents: []const AgentView = &.{},
    /// Wire page metadata; null denotes a complete view.
    page_offset: ?u64 = null,
    page_total: u64 = 0,
    group_id: u64 = 0,
    revision: u64 = 0,
    total: u64 = 0,
    running: u64 = 0,
    waiting: u64 = 0,
    completed: u64 = 0,
    failed: u64 = 0,
    canceled: u64 = 0,
    paused: u64 = 0,
    elapsed_ms: u64 = 0,
    latest_id: u64 = 0,
    text_len: u16 = 0,
    text_buf: [2048]u8 = @splat(0),

    pub fn latestText(self: *const View) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    pub fn active(self: View) bool {
        return self.running != 0 or self.waiting != 0;
    }

    /// Produces an independently owned snapshot. Release it with deinitOwned.
    pub fn clone(self: View, allocator: std.mem.Allocator) !View {
        var result = self;
        result.agents = if (self.agents.len == 0) &.{} else try allocator.dupe(AgentView, self.agents);
        return result;
    }

    /// Only call on a View obtained from clone (or an equivalent owned decoder).
    pub fn deinitOwned(self: *View, allocator: std.mem.Allocator) void {
        if (self.agents.len != 0) allocator.free(self.agents);
        self.* = .{};
    }

    pub fn eql(left: View, right: View) bool {
        var l = left;
        var r = right;
        l.agents = &.{};
        r.agents = &.{};
        if (!std.meta.eql(l, r) or left.agents.len != right.agents.len) return false;
        for (left.agents, right.agents) |a, b| {
            if (!std.meta.eql(a, b)) return false;
        }
        return true;
    }
};

test "per-agent status rows own cloned values" {
    var agents = [_]AgentView{.{ .id = 3, .phase = .running }};
    const borrowed: View = .{ .agents = &agents };
    var owned = try borrowed.clone(std.testing.allocator);
    defer owned.deinitOwned(std.testing.allocator);
    try std.testing.expect(View.eql(borrowed, owned));
    agents[0].phase = .failed;
    try std.testing.expect(!View.eql(borrowed, owned));
    try std.testing.expect(owned.agents[0].active());
}
