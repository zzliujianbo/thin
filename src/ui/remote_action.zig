//! Typed asynchronous UI commands. Queue admission is NOT remote success.
//! Owned requests retain exactly the submitted arguments until completion;
//! neither a moving editor nor a newer menu selection can change them.
const std = @import("std");
const session = @import("session_client.zig");
const runtime = @import("../core/runtime.zig");
const config = @import("../core/config.zig");
const settings = @import("../core/settings.zig");
const activity = @import("../presentation/activity.zig");
const Choice = @import("decision_picker.zig").Choice;
const codex_login = @import("../core/codex_login.zig");

pub const Setting = enum { low_price_input, decision_enabled };
pub const Action = union(enum) {
    submit: struct { kind: session.TaskKind, text: []const u8 },
    cancel,
    cancel_clear: u64,
    confirming: bool,
    approve: struct { id: u64, decision: runtime.Decision },
    enqueue: struct { kind: session.QueueKind, text: []const u8 },
    withdraw: u64,
    queue_resume,
    manage: session.Manage,
    configure: struct { provider: ?config.providers.Id, key: []const u8 },
    codex_login: struct { action: codex_login.Action, generation: u64 },
    model: []const u8,
    effort: activity.ReasoningEffort,
    cycle_effort,
    preference: struct { key: settings.Key, value: ?u32 },
    setting: struct { key: Setting, value: bool },
    decision: Choice,
    image: Choice,
    proxy: struct { model: []const u8, enabled: bool },
    proxy_address: []const u8,
    refresh_models,
    poll_metadata: bool,

    fn text(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
        if (bytes.len > session.max_item_bytes) return error.InputTooLarge;
        return a.dupe(u8, bytes);
    }

    fn copy(self: Action, a: std.mem.Allocator) !Action {
        return switch (self) {
            .submit => |v| .{ .submit = .{ .kind = v.kind, .text = try text(a, v.text) } },
            .enqueue => |v| .{ .enqueue = .{ .kind = v.kind, .text = try text(a, v.text) } },
            .configure => |v| .{ .configure = .{ .provider = v.provider, .key = try text(a, v.key) } },
            .model => |v| .{ .model = try text(a, v) },
            .proxy_address => |v| .{ .proxy_address = try text(a, v) },
            .proxy => |v| .{ .proxy = .{ .model = try text(a, v.model), .enabled = v.enabled } },
            .decision => |v| .{ .decision = switch (v) {
                .off => .off,
                .model => |name| .{ .model = try text(a, name) },
            } },
            .image => |v| .{ .image = switch (v) {
                .off => .off,
                .model => |name| .{ .model = try text(a, name) },
            } },
            .manage => |v| .{ .manage = switch (v) {
                .cd => |path| .{ .cd = try text(a, path) },
                .attach => |value| .{ .attach = .{ .id = try text(a, value.id), .takeover = value.takeover } },
                .close => |value| .{ .close = .{ .id = try text(a, value.id), .force = value.force } },
                else => v,
            } },
            else => self,
        };
    }
};

pub const Owned = struct {
    a: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    ticket: u64,
    generation: u64,
    epoch: u64,
    action: Action,

    pub fn create(a: std.mem.Allocator, ticket: u64, generation: u64, epoch: u64, action: Action) !*Owned {
        const self = try a.create(Owned);
        errdefer a.destroy(self);
        self.* = .{ .a = a, .arena = .init(a), .ticket = ticket, .generation = generation, .epoch = epoch, .action = undefined };
        errdefer self.arena.deinit();
        self.action = try action.copy(self.arena.allocator());
        return self;
    }

    pub fn deinit(self: *Owned) void {
        if (self.action == .configure) std.crypto.secureZero(u8, @constCast(self.action.configure.key));
        self.arena.deinit();
        const a = self.a;
        a.destroy(self);
    }
};

pub const Value = union(enum) {
    none,
    withdrawn: ?[]u8,
    managed: session.Outcome,
    effort: activity.ReasoningEffort,
    changed: bool,

    pub fn deinit(self: *Value, a: std.mem.Allocator) void {
        switch (self.*) {
            .withdrawn => |maybe| if (maybe) |bytes| a.free(bytes),
            .managed => |*value| value.deinit(a),
            else => {},
        }
        self.* = .none;
    }
};

pub const Completion = struct {
    request: *Owned,
    value: Value = .none,
    failure: ?anyerror = null,
    /// A newer view was already published. Retire pending UI bookkeeping, but
    /// do not restore old drafts, close new modals or display a stale success.
    obsolete: bool = false,

    pub fn deinit(self: *Completion) void {
        self.value.deinit(self.request.a);
        self.request.deinit();
        self.* = undefined;
    }
};

pub const Channel = struct {
    context: *anyopaque,
    start_fn: *const fn (*anyopaque, u64, Action) anyerror!u64,
    /// Transfers one completed request/result, never waits for a worker.
    poll_fn: *const fn (*anyopaque) ?Completion,
    /// Stable across session switches; valid until the adapter is joined.
    wake_fd: std.c.fd_t,

    pub fn start(self: Channel, epoch: u64, action: Action) !u64 {
        return self.start_fn(self.context, epoch, action);
    }
    pub fn poll(self: Channel) ?Completion {
        return self.poll_fn(self.context);
    }
};

test "asynchronous commands own text independently of the editor and retain identity" {
    var draft: [5]u8 = @splat('x');
    const request = try Owned.create(std.testing.allocator, 11, 9, 7, .{ .submit = .{ .kind = .prompt, .text = &draft } });
    defer request.deinit();
    @memset(&draft, 'y');
    try std.testing.expectEqualStrings("xxxxx", request.action.submit.text);
    try std.testing.expectEqual(@as(u64, 11), request.ticket);
    try std.testing.expectEqual(@as(u64, 9), request.generation);
    try std.testing.expectEqual(@as(u64, 7), request.epoch);
}
