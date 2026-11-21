//! Typed asynchronous UI commands. Queue admission is NOT remote success.
//! Owned requests retain exactly the submitted arguments until completion;
//! neither a moving editor nor a newer menu selection can change them.
const std = @import("std");
const session = @import("session_client.zig");
const runtime = @import("../core/runtime.zig");
const config = @import("../core/config.zig");
const settings = @import("../core/settings.zig");
const activity = @import("../presentation/activity.zig");
const Choice = @import("settings_model_picker.zig").Choice;
const codex_login = @import("../core/codex_login.zig");

pub const Action = union(enum) {
    submit: struct { kind: session.TaskKind, text: []const u8 },
    cancel,
    cancel_clear: u64,
    confirming: bool,
    approve: struct { id: u64, decision: runtime.Decision },
    enqueue: struct { kind: session.QueueKind, text: []const u8 },
    withdraw: u64,
    manage: session.Manage,
    configure: struct { provider: ?config.providers.Id, key: []const u8 },
    codex_login: struct { action: codex_login.Action, generation: u64 },
    model: []const u8,
    effort: activity.ReasoningEffort,
    cycle_effort,
    preference: struct { key: settings.Key, value: ?u32 },
    image: Choice,
    proxy: struct { model: []const u8, enabled: bool },
    proxy_address: []const u8,
    refresh_models,
    poll_metadata: bool,

    fn text(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
        return a.dupe(u8, bytes);
    }

    fn copy(self: Action, a: std.mem.Allocator) !Action {
        return switch (self) {
            .submit => |v| .{ .submit = .{ .kind = v.kind, .text = try text(a, v.text) } },
            .enqueue => |v| .{ .enqueue = .{ .kind = v.kind, .text = try text(a, v.text) } },
            .configure => |v| .{ .configure = .{ .provider = v.provider, .key = try text(a, v.key) } },
            .codex_login => |v| .{ .codex_login = .{
                .generation = v.generation,
                .action = switch (v.action) {
                    .start => .start,
                    .cancel => .cancel,
                    .submit => |callback| submit: {
                        if (callback.len > codex_login.max_callback_bytes) return error.InvalidOAuthCallback;
                        break :submit .{ .submit = try text(a, callback) };
                    },
                },
            } },
            .model => |v| .{ .model = try text(a, v) },
            .proxy_address => |v| .{ .proxy_address = try text(a, v) },
            .proxy => |v| .{ .proxy = .{ .model = try text(a, v.model), .enabled = v.enabled } },
            .image => |v| .{ .image = switch (v) {
                .off => .off,
                .model => |name| .{ .model = try text(a, name) },
            } },
            .manage => |v| .{ .manage = switch (v) {
                .@"resume" => |target| .{ .@"resume" = .{
                    .id = target.id,
                    .project = if (target.project) |path| try text(a, path) else null,
                } },
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
        switch (self.action) {
            .configure => |v| std.crypto.secureZero(u8, @constCast(v.key)),
            .codex_login => |v| switch (v.action) {
                .submit => |callback| std.crypto.secureZero(u8, @constCast(callback)),
                .start, .cancel => {},
            },
            else => {},
        }
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
